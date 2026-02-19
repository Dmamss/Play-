//
//  MemoryUtil_iOS.mm
//  Play! iOS - CodeGen JIT Mode Bridge Implementation
//
//  Bridges the Play! iOS JIT infrastructure (PlayJIT/StikDebug/BreakpointJIT)
//  into the CodeGen MemoryFunction system. Delegates to CMemoryFunctioniOS
//  for the actual runtime mode switching.
//

#include "MemoryUtil_iOS.h"
#include "MemoryFunction_iOS.h"
#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <sys/mman.h>
#import <libkern/OSCacheControl.h>
#import <unistd.h>
#import <sys/syscall.h>

// csops() syscall for checking CS_DEBUGGED flag (same as DolphiniOS)
// Use syscall directly like StikDebugJitService does - more reliable on iOS
#define CS_OPS_STATUS 0
#define CS_DEBUGGED 0x10000000

static int csops_wrapper(pid_t pid, unsigned int ops, void* useraddr, size_t usersize)
{
	return syscall(169, pid, ops, useraddr, usersize);
}

#if __has_include(<BreakpointJIT/BreakJIT.h>)
#import <BreakpointJIT/BreakJIT.h>
#define HAS_BREAKPOINTJIT 1
#else
#define HAS_BREAKPOINTJIT 0
#endif

// Default pre-allocation size (512MB for TXM, 128MB for NoTXM pool)
static constexpr size_t kDefaultRegionSize = 512 * 1024 * 1024;
static constexpr size_t kNoTxmPoolSize = 128 * 1024 * 1024;

// Region tracking for the UI layer
static bool s_regionAllocated = false;
static void* s_rwBase = nullptr;
static void* s_rxBase = nullptr;
static size_t s_regionSize = 0;

// Map CodeGen::JitType to CMemoryFunctioniOS::JitMode
static CMemoryFunctioniOS::JitMode MapJitType(CodeGen::JitType type)
{
	switch(type)
	{
	case CodeGen::JitType::LuckNoTXM:
		return CMemoryFunctioniOS::JitMode::LuckNoTXM;
	case CodeGen::JitType::LuckTXM:
		return CMemoryFunctioniOS::JitMode::LuckTXM;
	case CodeGen::JitType::Legacy:
	default:
		return CMemoryFunctioniOS::JitMode::Legacy;
	}
}

namespace CodeGen
{

	void SetJitType(JitType type)
	{
		NSLog(@"[MemoryUtil_iOS] JIT type set to: %s",
		      type == JitType::Legacy ? "Legacy" : type == JitType::LuckNoTXM ? "LuckNoTXM"
		                                                                      : "LuckTXM");

		// Forward to CodeGen's MemoryFunction runtime mode
		CMemoryFunctioniOS::SetJitMode(MapJitType(type));
	}

	JitType GetJitType()
	{
		auto mode = CMemoryFunctioniOS::GetJitMode();
		switch(mode)
		{
		case CMemoryFunctioniOS::JitMode::LuckNoTXM:
			return JitType::LuckNoTXM;
		case CMemoryFunctioniOS::JitMode::LuckTXM:
			return JitType::LuckTXM;
		case CMemoryFunctioniOS::JitMode::Legacy:
		default:
			return JitType::Legacy;
		}
	}

	void AllocateNoTxmPool()
	{
		size_t pageSize = getpagesize();
		size_t alignedSize = (kNoTxmPoolSize + pageSize - 1) & ~(pageSize - 1);

		NSLog(@"[MemoryUtil_iOS] Pre-allocating %zu byte LuckNoTXM pool...", alignedSize);

		void* rxPtr = mmap(nullptr, alignedSize, PROT_READ | PROT_EXEC,
		                   MAP_ANON | MAP_PRIVATE, -1, 0);
		if(rxPtr == MAP_FAILED)
		{
			NSLog(@"[MemoryUtil_iOS] LuckNoTXM pool mmap failed — will use per-block allocation");
			return;
		}

		vm_address_t rwAddr = 0;
		vm_prot_t curProt = 0, maxProt = 0;
		kern_return_t kr = vm_remap(mach_task_self(), &rwAddr, alignedSize, 0,
		                            VM_FLAGS_ANYWHERE, mach_task_self(),
		                            reinterpret_cast<vm_address_t>(rxPtr), FALSE,
		                            &curProt, &maxProt, VM_INHERIT_DEFAULT);
		if(kr != KERN_SUCCESS)
		{
			NSLog(@"[MemoryUtil_iOS] LuckNoTXM pool vm_remap failed: %d", kr);
			munmap(rxPtr, alignedSize);
			return;
		}

		if(mprotect(reinterpret_cast<void*>(rwAddr), alignedSize, PROT_READ | PROT_WRITE) != 0)
		{
			NSLog(@"[MemoryUtil_iOS] LuckNoTXM pool mprotect failed");
			vm_deallocate(mach_task_self(), rwAddr, alignedSize);
			munmap(rxPtr, alignedSize);
			return;
		}

		CMemoryFunctioniOS::SetLuckNoTXMRegion(reinterpret_cast<void*>(rwAddr), rxPtr, alignedSize);
		NSLog(@"[MemoryUtil_iOS] LuckNoTXM pool allocated: RW=%p RX=%p size=%zu",
		      (void*)rwAddr, rxPtr, alignedSize);
	}

	// Check if process has CS_DEBUGGED flag set (same method as DolphiniOS)
	// This is set when a debugger (like StikDebug) attaches to the process
	static bool IsProcessDebugged()
	{
		uint32_t flags = 0;
		int retval = csops_wrapper(getpid(), CS_OPS_STATUS, &flags, sizeof(flags));
		return retval == 0 && (flags & CS_DEBUGGED) != 0;
	}

	// Wait for debugger to attach by polling CS_DEBUGGED flag (same as DolphiniOS)
	static bool WaitUntilProcessDebugged(int timeout_seconds)
	{
		int time_left = timeout_seconds;

		while(time_left > 0)
		{
			if(IsProcessDebugged())
			{
				return true;
			}

			time_left--;
			usleep(1000000); // 1 second, same as DolphiniOS
		}

		return false;
	}

	bool WaitForDebuggerAttach(uint32_t timeout_ms)
	{
		NSLog(@"[MemoryUtil_iOS] Waiting for debugger (StikDebug) to attach...");

		// Convert ms to seconds for DolphiniOS-style polling
		int timeout_seconds = (timeout_ms + 999) / 1000;

		return WaitUntilProcessDebugged(timeout_seconds);
	}

	bool IsDebuggerAttached()
	{
		return IsProcessDebugged();
	}

	void AllocateExecutableMemoryRegion()
	{
		if(s_regionAllocated)
		{
			NSLog(@"[MemoryUtil_iOS] Executable memory region already allocated");
			return;
		}

		if(CMemoryFunctioniOS::GetJitMode() != CMemoryFunctioniOS::JitMode::LuckTXM)
		{
			NSLog(@"[MemoryUtil_iOS] AllocateExecutableMemoryRegion only applicable for LuckTXM mode");
			return;
		}

		size_t pageSize = getpagesize();
		size_t alignedSize = (kDefaultRegionSize + pageSize - 1) & ~(pageSize - 1);

		NSLog(@"[MemoryUtil_iOS] Allocating %zu byte executable memory region via BreakpointJIT...", alignedSize);

#if HAS_BREAKPOINTJIT
		// Check if debugger is attached using csops (same as DolphiniOS)
		// This must be checked BEFORE calling BreakGetJITMapping to avoid crash
		if(!IsProcessDebugged())
		{
			NSLog(@"[MemoryUtil_iOS] JIT is not active yet - debugger not attached (CS_DEBUGGED not set)");
			return;
		}

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
		    VM_INHERIT_DEFAULT);

		if(kr != KERN_SUCCESS)
		{
			NSLog(@"[MemoryUtil_iOS] vm_remap failed for RW alias: %d", kr);
			return;
		}

		// Set RW protection on the alias (mprotect, matching Dolphin)
		if(mprotect((void*)rwBase, alignedSize, PROT_READ | PROT_WRITE) != 0)
		{
			NSLog(@"[MemoryUtil_iOS] mprotect failed for RW alias: %d", errno);
			vm_deallocate(mach_task_self(), rwBase, alignedSize);
			return;
		}

		s_rxBase = rxBase;
		s_rwBase = (void*)rwBase;
		s_regionSize = alignedSize;
		s_regionAllocated = true;

		// Register with CodeGen's MemoryFunction so sub-allocations use this region
		CMemoryFunctioniOS::SetLuckTXMRegion(s_rwBase, s_rxBase, s_regionSize);

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
