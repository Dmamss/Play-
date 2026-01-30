#import "JITInitializer.h"
#include "CodeGen/MemoryUtil_iOS.h"
#import <Foundation/Foundation.h>
#import <sys/sysctl.h>
#import <sys/mman.h>

@implementation JITInitializer

+ (BOOL)deviceHasTXM
{
	// Check hw.cpufamily against known TXM chips (A15+/M2+).
	// The mmap probe (RWX|MAP_JIT) is NOT used because on iOS 26
	// it fails on ALL devices before CS_DEBUGGED is set, making it
	// impossible to distinguish TXM rejection from CSM rejection.
	uint32_t cpufamily = 0;
	size_t size = sizeof(cpufamily);
	if(sysctlbyname("hw.cpufamily", &cpufamily, &size, NULL, 0) == 0)
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
			NSLog(@"[JITInitializer] TXM detected via cpufamily 0x%08X", cpufamily);
			return YES;
		default:
			NSLog(@"[JITInitializer] cpufamily 0x%08X — no TXM", cpufamily);
			break;
		}
	}
	else
	{
		NSLog(@"[JITInitializer] WARNING: hw.cpufamily sysctl failed");
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
			NSLog(@"[JITInitializer] Configuring JIT: LuckNoTXM mode (iOS 26+ without TXM)");
			jitType = CodeGen::JitType::LuckNoTXM;
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
	auto jitType = CodeGen::GetJitType();

	if(jitType == CodeGen::JitType::LuckTXM)
	{
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
	else if(jitType == CodeGen::JitType::LuckNoTXM)
	{
		// Pre-allocate pooled region to avoid per-block mmap/vm_remap syscalls
		CodeGen::AllocateNoTxmPool();
	}
}

@end
