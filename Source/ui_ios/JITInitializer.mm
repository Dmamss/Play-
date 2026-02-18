#import "JITInitializer.h"
#include "CodeGen/MemoryUtil_iOS.h"
#import <Foundation/Foundation.h>
#import <sys/sysctl.h>
#import <sys/mman.h>

NSNotificationName const JITMemoryReadyNotification = @"JITMemoryReadyNotification";

/// Readiness tracking
static dispatch_semaphore_t s_jitReadySemaphore;
static BOOL s_jitReady = NO;
static dispatch_once_t s_semaphoreOnce;

/// Track if TXM allocation failed (StikDebug not attached)
static BOOL s_txmAllocationFailed = NO;

static dispatch_semaphore_t GetReadySemaphore()
{
	dispatch_once(&s_semaphoreOnce, ^{
	  s_jitReadySemaphore = dispatch_semaphore_create(0);
	});
	return s_jitReadySemaphore;
}

@implementation JITInitializer

+ (BOOL)deviceHasTXM
{
	// --- 1. Primary: check hw.cpufamily against known TXM chips ---
	uint32_t cpufamily = 0;
	size_t cpusize = sizeof(cpufamily);
	if(sysctlbyname("hw.cpufamily", &cpufamily, &cpusize, NULL, 0) == 0)
	{
		switch(cpufamily)
		{
		case 0xDA33D83D: // A15 Bionic
		case 0x8765EDEA: // A16 Bionic
		case 0xFA33415E: // A17 Pro
		case 0x5F4DEA93: // A18
		case 0x72015832: // A18 Pro
		case 0x6F5129AC: // M2
		case 0xDC6E3A2A: // M3
		case 0x041A314C: // M4
			return YES;
		default:
			break;
		}
	}

	// --- 2. Fallback: detect TXM via hw.machine model identifier ---
	char machine[64] = {0};
	size_t machsize = sizeof(machine);
	if(sysctlbyname("hw.machine", machine, &machsize, NULL, 0) == 0)
	{
		int major = 0;
		if(sscanf(machine, "iPhone%d", &major) == 1)
		{
			if(major >= 14) // iPhone14,x = A15 (first TXM iPhone)
				return YES;
		}
		else if(sscanf(machine, "iPad%d", &major) == 1)
		{
			if(major >= 13) // iPad13,x = M1/A15 (first TXM iPads)
				return YES;
		}
	}

	return NO;
}

+ (void)initializeJITSystem
{
	CodeGen::JitType jitType;

	if(@available(iOS 26, *))
	{
		BOOL hasTXM = [self deviceHasTXM];
		jitType = hasTXM ? CodeGen::JitType::LuckTXM : CodeGen::JitType::LuckNoTXM;
	}
	else
	{
		jitType = CodeGen::JitType::Legacy;
	}

	CodeGen::SetJitType(jitType);
}

+ (void)allocateExecutableMemoryIfNeeded
{
	if(s_jitReady) return;

	auto jitType = CodeGen::GetJitType();

	if(jitType == CodeGen::JitType::LuckTXM)
	{
		if(CodeGen::IsExecutableMemoryRegionAllocated())
		{
			[self signalReady];
			return;
		}

		NSLog(@"[JITInitializer] Allocating LuckTXM executable memory region...");
		CodeGen::AllocateExecutableMemoryRegion();

		if(!CodeGen::IsExecutableMemoryRegionAllocated())
		{
			// TXM allocation failed - StikDebug not attached or BreakpointJIT failed
			// On TXM devices, there's NO fallback - Legacy won't work!
			// Mark as failed so UI can show error to user
			NSLog(@"[JITInitializer] ERROR: TXM allocation failed - StikDebug not attached?");
			s_txmAllocationFailed = YES;
			[self signalReady]; // Signal ready so UI can check and show error
			return;
		}
		NSLog(@"[JITInitializer] LuckTXM region allocated successfully");
	}
	else if(jitType == CodeGen::JitType::LuckNoTXM)
	{
		NSLog(@"[JITInitializer] Allocating LuckNoTXM pool...");
		CodeGen::AllocateNoTxmPool();
		// NoTXM pool allocation is best-effort; individual blocks can fall back to per-block alloc
		NSLog(@"[JITInitializer] LuckNoTXM pool allocated (or fallback to per-block)");
	}
	else
	{
		NSLog(@"[JITInitializer] Legacy JIT mode - no pre-allocation needed");
	}

	[self signalReady];
}

+ (void)beginAsyncAllocation
{
	if(s_jitReady)
	{
		NSLog(@"[JITInitializer] Already ready, skipping async allocation");
		return;
	}

	NSLog(@"[JITInitializer] Starting async JIT memory allocation...");

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
	  [self allocateExecutableMemoryIfNeeded];
	});
}

+ (BOOL)isReady
{
	return s_jitReady;
}

+ (BOOL)waitForReadiness:(NSTimeInterval)timeout
{
	if(s_jitReady) return YES;

	auto jitType = CodeGen::GetJitType();
	if(jitType == CodeGen::JitType::Legacy)
	{
		// Legacy mode doesn't need pre-allocation
		[self signalReady];
		return YES;
	}

	if(timeout <= 0) return s_jitReady;

	NSLog(@"[JITInitializer] Waiting for JIT readiness (timeout: %.1fs)...", timeout);
	dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
	long result = dispatch_semaphore_wait(GetReadySemaphore(), deadline);

	if(result == 0)
	{
		// Re-signal so other waiters also unblock
		dispatch_semaphore_signal(GetReadySemaphore());
		NSLog(@"[JITInitializer] JIT ready");
		return YES;
	}
	else
	{
		NSLog(@"[JITInitializer] Timed out waiting for JIT readiness");
		return NO;
	}
}

+ (void)signalReady
{
	if(s_jitReady) return;
	s_jitReady = YES;
	dispatch_semaphore_signal(GetReadySemaphore());

	// Post notification (on main thread for UI observers)
	dispatch_async(dispatch_get_main_queue(), ^{
	  [[NSNotificationCenter defaultCenter] postNotificationName:JITMemoryReadyNotification object:nil];
	});
}

+ (BOOL)requiresTXM
{
	if(@available(iOS 26, *))
	{
		return [self deviceHasTXM];
	}
	return NO;
}

+ (BOOL)isJITAvailable
{
	if(!s_jitReady) return NO;

	auto jitType = CodeGen::GetJitType();

	if(jitType == CodeGen::JitType::LuckTXM)
	{
		// TXM requires StikDebug - check if allocation succeeded
		return CodeGen::IsExecutableMemoryRegionAllocated() && !s_txmAllocationFailed;
	}
	else if(jitType == CodeGen::JitType::LuckNoTXM)
	{
		// NoTXM can work with per-block fallback, always available
		return YES;
	}
	else
	{
		// Legacy mode - available on older iOS
		return YES;
	}
}

+ (NSString*)jitUnavailableReason
{
	if(!s_jitReady)
	{
		return @"JIT system not initialized";
	}

	if([self isJITAvailable])
	{
		return nil; // JIT is available, no error
	}

	auto jitType = CodeGen::GetJitType();

	if(jitType == CodeGen::JitType::LuckTXM && s_txmAllocationFailed)
	{
		return @"JIT requires StikDebug on this device.\n\n"
		       @"This device has a TXM chip (A15 or newer) running iOS 26+, "
		       @"which requires StikDebug to enable JIT.\n\n"
		       @"Please:\n"
		       @"1. Install StikDebug (v2.3.0+)\n"
		       @"2. Launch StikDebug and enable JIT for Play!\n"
		       @"3. Return to Play!";
	}

	return @"JIT is not available on this device configuration";
}

+ (BOOL)isDebuggerAttached
{
	return CodeGen::IsDebuggerAttached();
}

+ (BOOL)waitForJITWithTimeout:(NSTimeInterval)timeout
                progressBlock:(void (^)(float progress, NSString* status))progressBlock
{
	auto jitType = CodeGen::GetJitType();

	// Non-TXM modes don't need to wait for debugger
	if(jitType != CodeGen::JitType::LuckTXM)
	{
		if(progressBlock)
		{
			progressBlock(1.0f, @"JIT Ready");
		}
		[self allocateExecutableMemoryIfNeeded];
		return [self isJITAvailable];
	}

	// TXM mode - need to wait for StikDebug to attach
	NSLog(@"[JITInitializer] Waiting for StikDebug to attach (timeout: %.1fs)...", timeout);

	if(progressBlock)
	{
		progressBlock(0.0f, @"Waiting for StikDebug...");
	}

	// Poll for debugger attachment with progress updates
	NSTimeInterval startTime = [[NSDate date] timeIntervalSince1970];
	NSTimeInterval checkInterval = 0.5; // Check every 500ms
	int iteration = 0;

	while(true)
	{
		// Check if debugger is attached
		if(CodeGen::IsDebuggerAttached())
		{
			NSLog(@"[JITInitializer] StikDebug attached! Allocating JIT memory...");

			if(progressBlock)
			{
				progressBlock(0.9f, @"Allocating JIT memory...");
			}

			// Debugger attached - now allocate the JIT region
			[self allocateExecutableMemoryIfNeeded];

			if(CodeGen::IsExecutableMemoryRegionAllocated())
			{
				NSLog(@"[JITInitializer] JIT memory allocated successfully");
				if(progressBlock)
				{
					progressBlock(1.0f, @"JIT Ready!");
				}
				return YES;
			}
			else
			{
				NSLog(@"[JITInitializer] JIT memory allocation failed");
				if(progressBlock)
				{
					progressBlock(1.0f, @"Allocation failed");
				}
				return NO;
			}
		}

		// Check timeout
		NSTimeInterval elapsed = [[NSDate date] timeIntervalSince1970] - startTime;
		if(elapsed >= timeout)
		{
			NSLog(@"[JITInitializer] Timeout waiting for StikDebug");
			s_txmAllocationFailed = YES;
			[self signalReady];
			return NO;
		}

		// Update progress
		if(progressBlock)
		{
			float progress = (float)(elapsed / timeout) * 0.8f; // Cap at 80% while waiting
			NSString* status;
			switch(iteration % 4)
			{
			case 0:
				status = @"Waiting for StikDebug...";
				break;
			case 1:
				status = @"Open StikDebug app";
				break;
			case 2:
				status = @"Enable JIT for Play!";
				break;
			case 3:
				status = @"Then return here";
				break;
			default:
				status = @"Waiting...";
				break;
			}
			progressBlock(progress, status);
		}

		iteration++;

		// Wait before next check
		[NSThread sleepForTimeInterval:checkInterval];
	}
}

@end
