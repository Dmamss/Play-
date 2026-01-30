#import "JITInitializer.h"
#include "CodeGen/MemoryUtil_iOS.h"
#import <Foundation/Foundation.h>
#import <sys/stat.h>

@implementation JITInitializer

+ (BOOL)deviceHasTXM
{
	// Detect TXM (Trusted Execution Monitor) presence
	// Based on StikDebug implementation
	// Checks for: /System/Volumes/Preboot/<36 chars>/boot/<96 chars>/usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4

	NSFileManager* fileManager = [NSFileManager defaultManager];
	NSError* error = nil;

	// Primary path
	NSArray<NSString*>* prebootContents = [fileManager contentsOfDirectoryAtPath:@"/System/Volumes/Preboot" error:&error];
	if(prebootContents)
	{
		for(NSString* uuid in prebootContents)
		{
			if(uuid.length == 36)
			{
				NSString* bootPath = [NSString stringWithFormat:@"/System/Volumes/Preboot/%@/boot", uuid];
				NSArray<NSString*>* bootContents = [fileManager contentsOfDirectoryAtPath:bootPath error:nil];
				if(bootContents)
				{
					for(NSString* hash in bootContents)
					{
						if(hash.length == 96)
						{
							NSString* txmPath = [NSString stringWithFormat:@"%@/%@/usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4", bootPath, hash];
							if([fileManager fileExistsAtPath:txmPath])
							{
								return YES;
							}
						}
					}
				}
			}
		}
	}

	// Fallback path
	NSArray<NSString*>* privatePrebootContents = [fileManager contentsOfDirectoryAtPath:@"/private/preboot" error:nil];
	if(privatePrebootContents)
	{
		for(NSString* hash in privatePrebootContents)
		{
			if(hash.length == 96)
			{
				NSString* txmPath = [NSString stringWithFormat:@"/private/preboot/%@/usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4", hash];
				if([fileManager fileExistsAtPath:txmPath])
				{
					return YES;
				}
			}
		}
	}

	return NO;
}

+ (void)initializeJITSystem
{
	NSLog(@"[JITInitializer] Detecting JIT mode...");

	CodeGen::JitType jitType;

	if(@available(iOS 26, *))
	{
		BOOL hasTXM = [self deviceHasTXM];

		if(hasTXM)
		{
			NSLog(@"[JITInitializer] Configuring JIT: LuckTXM mode (iOS 26+ with TXM)");
			jitType = CodeGen::JitType::LuckTXM;
		}
		else
		{
			// Non-TXM iOS 26+ (A12-A14, M1): use Legacy vm_protect toggle
			// Same approach as DolphiniOS — vm_remap dual mapping is not needed
			// when CS_DEBUGGED allows vm_protect with EXECUTE permission
			NSLog(@"[JITInitializer] Configuring JIT: Legacy mode (iOS 26+ without TXM)");
			jitType = CodeGen::JitType::Legacy;
		}
	}
	else
	{
		NSLog(@"[JITInitializer] Configuring JIT: Legacy mode (iOS < 26)");
		jitType = CodeGen::JitType::Legacy;
	}

	// Only set the mode — do NOT allocate memory yet.
	// For LuckTXM, the debugger must be attached first (via StikDebug).
	// Call allocateExecutableMemoryIfNeeded after activation.
	CodeGen::SetJitType(jitType);

	NSLog(@"[JITInitializer] JIT mode configured (allocation deferred)");
}

+ (void)allocateExecutableMemoryIfNeeded
{
	if(CodeGen::GetJitType() != CodeGen::JitType::LuckTXM)
	{
		return;
	}

	if(CodeGen::IsExecutableMemoryRegionAllocated())
	{
		NSLog(@"[JITInitializer] Executable memory region already allocated");
		return;
	}

	NSLog(@"[JITInitializer] Allocating 512MB executable memory region via BreakpointJIT...");
	CodeGen::AllocateExecutableMemoryRegion();

	if(CodeGen::IsExecutableMemoryRegionAllocated())
	{
		NSLog(@"[JITInitializer] Region allocated: RW=%p RX=%p size=%zu",
		      CodeGen::GetExecutableMemoryRWBase(),
		      CodeGen::GetExecutableMemoryRXBase(),
		      CodeGen::GetExecutableMemoryRegionSize());
	}
	else
	{
		NSLog(@"[JITInitializer] ERROR: Failed to allocate executable memory region");
	}
}

@end
