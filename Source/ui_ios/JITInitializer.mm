#import "JITInitializer.h"
#include "CodeGen/MemoryUtil_iOS.h"
#import <Foundation/Foundation.h>
#import <sys/sysctl.h>
#import <sys/mman.h>

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
	// TXM is present on A15+ chips. Device model numbers that have TXM:
	//   iPhone14,x and later (A15+)
	//   iPad13,x and later (M1/A15+)
	// Parse the major model number to detect TXM generically.
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
	auto jitType = CodeGen::GetJitType();

	if(jitType == CodeGen::JitType::LuckTXM)
	{
		if(CodeGen::IsExecutableMemoryRegionAllocated())
			return;

		CodeGen::AllocateExecutableMemoryRegion();

		if(!CodeGen::IsExecutableMemoryRegionAllocated())
		{
			NSLog(@"[JITInitializer] ERROR: Failed to allocate executable memory region");
		}
	}
	else if(jitType == CodeGen::JitType::LuckNoTXM)
	{
		CodeGen::AllocateNoTxmPool();
	}
}

@end
