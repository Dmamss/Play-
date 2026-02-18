#pragma once

//
//  MemoryUtil_iOS.h
//  Play! iOS - CodeGen JIT Mode Bridge
//
//  Provides runtime JIT mode selection for iOS 26+ TXM support.
//  This bridges the Play! iOS JIT infrastructure (PlayJIT/StikDebug)
//  into the CodeGen MemoryFunction system.
//
//  Three JIT modes:
//    Legacy    - iOS < 26: Mach VM with vm_allocate/vm_protect (W^X toggle)
//    LuckNoTXM - iOS 26+ without TXM: mmap with dual RW/RX mapping per allocation
//    LuckTXM   - iOS 26+ with TXM: BreakpointJIT pre-allocated 512MB region
//

#include <cstddef>
#include <cstdint>

namespace CodeGen
{
	enum class JitType
	{
		Legacy,    // iOS < 26: Standard Mach VM W^X toggle
		LuckNoTXM, // iOS 26+ without TXM: RW/RX mirror per allocation
		LuckTXM    // iOS 26+ with TXM: Pre-allocated region via BreakpointJIT
	};

	/// Set the JIT mode for all subsequent memory allocations.
	/// Must be called before any CodeGen memory allocation.
	void SetJitType(JitType type);

	/// Get the currently configured JIT type.
	JitType GetJitType();

	/// Pre-allocate the executable memory region for LuckTXM mode.
	/// Allocates a large (512MB) region via BreakpointJIT for use by the JIT compiler.
	void AllocateExecutableMemoryRegion();

	/// Pre-allocate a pooled dual-mapped region for LuckNoTXM mode.
	/// Eliminates per-block mmap/vm_remap syscalls for much faster JIT allocation.
	/// Falls back gracefully to per-block allocation if pool creation fails.
	void AllocateNoTxmPool();

	/// Check if the executable memory region has been allocated.
	bool IsExecutableMemoryRegionAllocated();

	/// Get the RW base pointer of the pre-allocated region (LuckTXM mode).
	void* GetExecutableMemoryRWBase();

	/// Get the RX base pointer of the pre-allocated region (LuckTXM mode).
	void* GetExecutableMemoryRXBase();

	/// Get the size of the pre-allocated region.
	size_t GetExecutableMemoryRegionSize();

	/// Wait for debugger (StikDebug) to attach. For TXM devices.
	/// @param timeout_ms Maximum time to wait in milliseconds
	/// @return true if debugger attached within timeout
	bool WaitForDebuggerAttach(uint32_t timeout_ms);

	/// Check if debugger (StikDebug) is currently attached.
	/// @return true if CS_DEBUGGED flag is set
	bool IsDebuggerAttached();

} // namespace CodeGen
