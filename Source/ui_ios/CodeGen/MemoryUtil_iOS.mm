//
//  MemoryUtil_iOS.mm
//  Play! iOS - CodeGen JIT Mode Bridge Implementation
//
//  Implements runtime JIT mode selection and memory region management
//  for iOS 26+ TXM support using BreakpointJIT/PlayJIT.
//

#include "MemoryUtil_iOS.h"
#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <sys/mman.h>
#import <libkern/OSCacheControl.h>

#if __has_include(<BreakpointJIT/BreakJIT.h>)
#import <BreakpointJIT/BreakJIT.h>
#define HAS_BREAKPOINTJIT 1
#else
#define HAS_BREAKPOINTJIT 0
#endif

// Default pre-allocation size for LuckTXM mode (512MB)
static constexpr size_t kDefaultRegionSize = 512 * 1024 * 1024;

// Module state
static CodeGen::JitType s_jitType = CodeGen::JitType::Legacy;
static bool s_regionAllocated = false;
static void* s_rwBase = nullptr;
static void* s_rxBase = nullptr;
static size_t s_regionSize = 0;

namespace CodeGen
{

	void SetJitType(JitType type)
	{
		s_jitType = type;
		NSLog(@"[MemoryUtil_iOS] JIT type set to: %s",
		      type == JitType::Legacy ? "Legacy" : type == JitType::LuckNoTXM ? "LuckNoTXM"
		                                                                      : "LuckTXM");
	}

	JitType GetJitType()
	{
		return s_jitType;
	}

	void AllocateExecutableMemoryRegion()
	{
		if(s_regionAllocated)
		{
			NSLog(@"[MemoryUtil_iOS] Executable memory region already allocated");
			return;
		}

		if(s_jitType != JitType::LuckTXM)
		{
			NSLog(@"[MemoryUtil_iOS] AllocateExecutableMemoryRegion only applicable for LuckTXM mode");
			return;
		}

		size_t pageSize = getpagesize();
		size_t alignedSize = (kDefaultRegionSize + pageSize - 1) & ~(pageSize - 1);

		NSLog(@"[MemoryUtil_iOS] Allocating %zu byte executable memory region via BreakpointJIT...", alignedSize);

#if HAS_BREAKPOINTJIT
		// Use BreakpointJIT to allocate RX memory from StikDebug
		void* rxBase = BreakGetJITMapping(NULL, alignedSize);
		if(!rxBase)
		{
			NSLog(@"[MemoryUtil_iOS] BreakGetJITMapping failed for region allocation");
			return;
		}

		// Create RW alias via vm_remap
		vm_address_t rwBase = 0;
		vm_prot_t curProt, maxProt;

		kern_return_t kr = vm_remap(
		    mach_task_self(),
		    &rwBase,
		    alignedSize,
		    0,
		    VM_FLAGS_ANYWHERE,
		    mach_task_self(),
		    (vm_address_t)rxBase,
		    FALSE,
		    &curProt,
		    &maxProt,
		    VM_INHERIT_NONE);

		if(kr != KERN_SUCCESS)
		{
			NSLog(@"[MemoryUtil_iOS] vm_remap failed for RW alias: %d", kr);
			return;
		}

		// Set RW protection on the alias
		kr = vm_protect(mach_task_self(), rwBase, alignedSize, FALSE,
		                VM_PROT_READ | VM_PROT_WRITE);

		if(kr != KERN_SUCCESS)
		{
			NSLog(@"[MemoryUtil_iOS] vm_protect failed for RW alias: %d", kr);
			vm_deallocate(mach_task_self(), rwBase, alignedSize);
			return;
		}

		s_rxBase = rxBase;
		s_rwBase = (void*)rwBase;
		s_regionSize = alignedSize;
		s_regionAllocated = true;

		NSLog(@"[MemoryUtil_iOS] Executable memory region allocated: RW=%p RX=%p size=%zu",
		      s_rwBase, s_rxBase, s_regionSize);
#else
		NSLog(@"[MemoryUtil_iOS] BreakpointJIT not available - cannot allocate LuckTXM region");
#endif
	}

	bool IsExecutableMemoryRegionAllocated()
	{
		return s_regionAllocated;
	}

	void* GetExecutableMemoryRWBase()
	{
		return s_rwBase;
	}

	void* GetExecutableMemoryRXBase()
	{
		return s_rxBase;
	}

	size_t GetExecutableMemoryRegionSize()
	{
		return s_regionSize;
	}

} // namespace CodeGen
