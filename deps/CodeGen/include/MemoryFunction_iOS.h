#pragma once

#include <cstddef>

namespace CMemoryFunctioniOS
{
	enum class JitMode
	{
		Legacy    = 0, // iOS < 26: standard Mach VM W^X toggle (vm_allocate + vm_protect)
		LuckNoTXM = 1, // iOS 26+ without TXM: dual RW/RX mapping via vm_remap
		LuckTXM   = 2, // iOS 26+ with TXM: pre-allocated region from BreakpointJIT/StikDebug
	};

	void   SetJitMode(JitMode mode);
	JitMode GetJitMode();

	// LuckTXM: called once after BreakGetJITMapping to register the pre-allocated region
	void   SetLuckTXMRegion(void* rwBase, void* rxBase, size_t size);

	// Returns the current bump-allocator offset inside the TXM region
	size_t GetLuckTXMOffset();
}
