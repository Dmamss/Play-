#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <algorithm>
#include <cstdint>
#include "AlignedAlloc.h"
#include "MemoryFunction.h"

// clang-format off

#define BLOCK_ALIGN 0x10

#ifdef _WIN32
	#define MEMFUNC_USE_WIN32
#elif defined(__APPLE__)
	#include "TargetConditionals.h"
	#include <libkern/OSCacheControl.h>

	#if TARGET_OS_OSX
		#define MEMFUNC_USE_MMAP
		#define MEMFUNC_MMAP_ADDITIONAL_FLAGS (MAP_JIT)
		#if TARGET_CPU_ARM64
			#define MEMFUNC_MMAP_REQUIRES_JIT_WRITE_PROTECT
		#endif
	#else
		#define MEMFUNC_USE_MACHVM
		#if TARGET_OS_IPHONE
			#define MEMFUNC_MACHVM_STRICT_PROTECTION
			#define MEMFUNC_IOS_RUNTIME_JIT_MODES
		#endif
	#endif
#elif defined(__EMSCRIPTEN__)
	#include <emscripten.h>
	#define MEMFUNC_USE_WASM
#else
	#define MEMFUNC_USE_MMAP
#endif

#if defined(MEMFUNC_USE_WIN32)
#include <windows.h>
#elif defined(MEMFUNC_USE_MACHVM)
#include <mach/mach_init.h>
#include <mach/vm_map.h>
#include <sys/mman.h>
#include <unistd.h>
#elif defined(MEMFUNC_USE_MMAP)
#include <sys/mman.h>
#include <pthread.h>
#elif defined(MEMFUNC_USE_WASM)
EM_JS_DEPS(WasmMemoryFunction, "$addFunction,$removeFunction");
EM_JS(int, WasmCreateFunction, (emscripten::EM_VAL moduleHandle),
{
	let module = Emval.toValue(moduleHandle);
	let moduleInstance = new WebAssembly.Instance(module, {
		env: {
			memory: wasmMemory,
			fctTable : Module.codeGenImportTable
		}
	});
	let fct = moduleInstance.exports.codeGenFunc;
	let fctId = addFunction(fct, 'vi');
	return fctId;
});
EM_JS(void, WasmDeleteFunction, (int fctId),
{
	removeFunction(fctId);
});
EM_JS(emscripten::EM_VAL, WasmCreateModule, (uintptr_t code, uintptr_t size),
{
	//var fs = require('fs');
	let moduleBytes = HEAP8.subarray(code, code + size);
	//fs.writeFileSync('module.wasm', moduleBytes);
	//{
	//	let bytesCopy = new Uint8Array(moduleBytes);
	//	let blob = new Blob([bytesCopy], { type: "binary/octet-stream" });
	//	let url = URL.createObjectURL(blob);
	//	console.log(url);
	//}
	let module = new WebAssembly.Module(moduleBytes);
	return Emval.toHandle(module);
});
#else
#error "No API to use for CMemoryFunction"
#endif

#if defined(MEMFUNC_IOS_RUNTIME_JIT_MODES)
#include "MemoryFunction_iOS.h"
#include <mutex>
#include <atomic>
#include <tuple>

// ─── CMemoryFunctioniOS namespace implementation ───
namespace
{
	static CMemoryFunctioniOS::JitMode s_jitMode = CMemoryFunctioniOS::JitMode::Legacy;

	// LuckTXM pre-allocated region state
	static void*                s_txmRWBase  = nullptr;
	static void*                s_txmRXBase  = nullptr;
	static size_t               s_txmSize    = 0;
	static std::atomic<size_t>  s_txmOffset{0};
	static std::mutex           s_txmMutex;

	// LuckNoTXM pre-allocated pool state (avoids per-block mmap/vm_remap)
	static void*                s_noTxmRWBase  = nullptr;
	static void*                s_noTxmRXBase  = nullptr;
	static size_t               s_noTxmSize    = 0;
	static std::atomic<size_t>  s_noTxmOffset{0};
}

namespace CMemoryFunctioniOS
{
	void SetJitMode(JitMode mode)       { s_jitMode = mode; }
	JitMode GetJitMode()                { return s_jitMode; }

	void SetLuckTXMRegion(void* rwBase, void* rxBase, size_t size)
	{
		std::lock_guard<std::mutex> lock(s_txmMutex);
		s_txmRWBase = rwBase;
		s_txmRXBase = rxBase;
		s_txmSize   = size;
		s_txmOffset.store(0, std::memory_order_relaxed);
	}

	size_t GetLuckTXMOffset() { return s_txmOffset.load(std::memory_order_relaxed); }

	void SetLuckNoTXMRegion(void* rwBase, void* rxBase, size_t size)
	{
		s_noTxmRWBase = rwBase;
		s_noTxmRXBase = rxBase;
		s_noTxmSize   = size;
		s_noTxmOffset.store(0, std::memory_order_relaxed);
	}
}

// Thread-safe bump allocator inside the pre-allocated TXM region.
// Returns {rwPtr, rxPtr, allocSize} or {nullptr, nullptr, 0} on failure.
static std::tuple<void*, void*, size_t> TxmSubAllocate(size_t size)
{
	vm_size_t page_size = 0;
	host_page_size(mach_task_self(), &page_size);
	size_t allocSize = ((size + page_size - 1) / page_size) * page_size;

	size_t offset = s_txmOffset.fetch_add(allocSize, std::memory_order_relaxed);
	if(offset + allocSize > s_txmSize)
	{
		// Roll back – out of space
		s_txmOffset.fetch_sub(allocSize, std::memory_order_relaxed);
		return {nullptr, nullptr, 0};
	}

	void* rwPtr = reinterpret_cast<uint8_t*>(s_txmRWBase) + offset;
	void* rxPtr = reinterpret_cast<uint8_t*>(s_txmRXBase) + offset;
	return {rwPtr, rxPtr, allocSize};
}

// Thread-safe bump allocator inside the pre-allocated LuckNoTXM pool.
// Returns {rwPtr, rxPtr, allocSize} or falls back to per-block allocation.
static std::tuple<void*, void*, size_t> NoTxmPoolSubAllocate(size_t size)
{
	if(!s_noTxmRWBase) return {nullptr, nullptr, 0};

	size_t page_size = sysconf(_SC_PAGESIZE);
	size_t allocSize = ((size + page_size - 1) / page_size) * page_size;

	// CAS loop to avoid temporarily corrupting the offset on overflow
	size_t offset = s_noTxmOffset.load(std::memory_order_relaxed);
	while(true)
	{
		if(offset + allocSize > s_noTxmSize)
			return {nullptr, nullptr, 0};
		if(s_noTxmOffset.compare_exchange_weak(offset, offset + allocSize,
		                                       std::memory_order_relaxed))
			break;
	}

	void* rwPtr = reinterpret_cast<uint8_t*>(s_noTxmRWBase) + offset;
	void* rxPtr = reinterpret_cast<uint8_t*>(s_noTxmRXBase) + offset;
	return {rwPtr, rxPtr, allocSize};
}

// Per-block dual-mapped allocation (fallback when pool is not available).
// Matching DolphiniOS approach: mmap RX first, vm_remap for RW alias.
static std::tuple<void*, void*, size_t> LuckNoTxmAllocateFallback(size_t size)
{
	size_t page_size = sysconf(_SC_PAGESIZE);
	size_t allocSize = ((size + page_size - 1) / page_size) * page_size;

	void* rxPtr = mmap(nullptr, allocSize, PROT_READ | PROT_EXEC,
	                   MAP_ANON | MAP_PRIVATE, -1, 0);
	if(rxPtr == MAP_FAILED) return {nullptr, nullptr, 0};

	vm_address_t rwAddr = 0;
	vm_prot_t curProt = 0;
	vm_prot_t maxProt = 0;
	kern_return_t kr = vm_remap(mach_task_self(), &rwAddr, allocSize, 0,
	                            VM_FLAGS_ANYWHERE, mach_task_self(),
	                            reinterpret_cast<vm_address_t>(rxPtr), FALSE,
	                            &curProt, &maxProt, VM_INHERIT_DEFAULT);
	if(kr != KERN_SUCCESS)
	{
		munmap(rxPtr, allocSize);
		return {nullptr, nullptr, 0};
	}

	if(mprotect(reinterpret_cast<void*>(rwAddr), allocSize, PROT_READ | PROT_WRITE) != 0)
	{
		vm_deallocate(mach_task_self(), rwAddr, allocSize);
		munmap(rxPtr, allocSize);
		return {nullptr, nullptr, 0};
	}

	return {reinterpret_cast<void*>(rwAddr), rxPtr, allocSize};
}

// LuckNoTXM allocation: try pool first, fall back to per-block.
static std::tuple<void*, void*, size_t> LuckNoTxmAllocate(size_t size)
{
	auto result = NoTxmPoolSubAllocate(size);
	if(std::get<0>(result)) return result;
	return LuckNoTxmAllocateFallback(size);
}
#endif // MEMFUNC_IOS_RUNTIME_JIT_MODES

CMemoryFunction::CMemoryFunction()
: m_code(nullptr)
, m_size(0)
{

}

CMemoryFunction::CMemoryFunction(CMemoryFunction&& rhs)
: m_code(nullptr)
, m_size(0)
{
	std::swap(m_code, rhs.m_code);
	std::swap(m_size, rhs.m_size);
#if defined(__APPLE__) && TARGET_OS_IPHONE
	std::swap(m_codeRW, rhs.m_codeRW);
	std::swap(m_dualMapped, rhs.m_dualMapped);
	std::swap(m_fromPool, rhs.m_fromPool);
#endif
#if defined(MEMFUNC_USE_WASM)
	std::swap(m_wasmModule, rhs.m_wasmModule);
#endif
}

CMemoryFunction::CMemoryFunction(const void* code, size_t size)
: m_code(nullptr)
{
#if defined(MEMFUNC_USE_WIN32)
	m_size = size;
	m_code = framework_aligned_alloc(size, BLOCK_ALIGN);
	memcpy(m_code, code, size);
	
	DWORD oldProtect = 0;
	BOOL result = VirtualProtect(m_code, size, PAGE_EXECUTE_READWRITE, &oldProtect);
	assert(result == TRUE);
#elif defined(MEMFUNC_USE_MACHVM)
#if defined(MEMFUNC_IOS_RUNTIME_JIT_MODES)
	{
		auto mode = CMemoryFunctioniOS::GetJitMode();
		bool usedFallback = false;

		if(mode == CMemoryFunctioniOS::JitMode::LuckTXM)
		{
			auto [rwPtr, rxPtr, aSize] = TxmSubAllocate(size);
			if(rwPtr != nullptr)
			{
				m_codeRW       = rwPtr;
				m_code         = rxPtr; // RX view – used for execution
				m_size         = aSize;
				m_dualMapped   = true;
				m_fromPool     = true;
				memcpy(m_codeRW, code, size);
				sys_icache_invalidate(m_code, m_size); // Flush instruction cache for RX view
			}
			else
			{
				// TXM region not allocated or exhausted - fall back to Legacy
				usedFallback = true;
			}
		}
		else if(mode == CMemoryFunctioniOS::JitMode::LuckNoTXM)
		{
			auto [rwPtr, rxPtr, aSize] = LuckNoTxmAllocate(size);
			if(rwPtr != nullptr)
			{
				m_codeRW     = rwPtr;
				m_code       = rxPtr;
				m_size       = aSize;
				m_dualMapped = true;
				m_fromPool   = (s_noTxmRWBase != nullptr &&
				                reinterpret_cast<uint8_t*>(rwPtr) >= reinterpret_cast<uint8_t*>(s_noTxmRWBase) &&
				                reinterpret_cast<uint8_t*>(rwPtr) < reinterpret_cast<uint8_t*>(s_noTxmRWBase) + s_noTxmSize);
				memcpy(m_codeRW, code, size);
				sys_icache_invalidate(m_code, m_size); // Flush instruction cache for RX view
			}
			else
			{
				// NoTXM allocation failed - fall back to Legacy
				usedFallback = true;
			}
		}
		else
		{
			// Legacy mode requested directly
			usedFallback = true;
		}

		if(usedFallback)
		{
			// Legacy allocation: vm_allocate + vm_protect (works without JIT entitlement for interpreter)
			vm_size_t page_size = 0;
			host_page_size(mach_task_self(), &page_size);
			unsigned int allocSize = ((size + page_size - 1) / page_size) * page_size;
			kern_return_t allocResult = vm_allocate(mach_task_self(), reinterpret_cast<vm_address_t*>(&m_code), allocSize, TRUE);
			if(allocResult != KERN_SUCCESS || m_code == nullptr)
			{
				// Complete allocation failure - this will leave m_code as nullptr
				// which IsEmpty() will detect
				m_code = nullptr;
				m_size = 0;
				return;
			}
			memcpy(m_code, code, size);
			vm_prot_t protection = VM_PROT_READ | VM_PROT_EXECUTE;
			kern_return_t result = vm_protect(mach_task_self(), reinterpret_cast<vm_address_t>(m_code), size, 0, protection);
			if(result != KERN_SUCCESS)
			{
				// Protection change failed - cleanup and mark as empty
				vm_deallocate(mach_task_self(), reinterpret_cast<vm_address_t>(m_code), allocSize);
				m_code = nullptr;
				m_size = 0;
				return;
			}
			m_size = allocSize;
			m_dualMapped = false;
			m_fromPool = false;
			sys_icache_invalidate(m_code, m_size); // Flush instruction cache
		}
	}
#else
	vm_size_t page_size = 0;
	host_page_size(mach_task_self(), &page_size);
	unsigned int allocSize = ((size + page_size - 1) / page_size) * page_size;
	vm_allocate(mach_task_self(), reinterpret_cast<vm_address_t*>(&m_code), allocSize, TRUE);
	memcpy(m_code, code, size);
	vm_prot_t protection =
	#ifdef MEMFUNC_MACHVM_STRICT_PROTECTION
		VM_PROT_READ | VM_PROT_EXECUTE;
	#else
		VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE;
	#endif
	kern_return_t result = vm_protect(mach_task_self(), reinterpret_cast<vm_address_t>(m_code), size, 0, protection);
	assert(result == 0);
	m_size = allocSize;
	sys_icache_invalidate(m_code, m_size); // Flush instruction cache
#endif
#elif defined(MEMFUNC_USE_MMAP)
	uint32 additionalMapFlags = 0;
	#ifdef MEMFUNC_MMAP_ADDITIONAL_FLAGS
		additionalMapFlags = MEMFUNC_MMAP_ADDITIONAL_FLAGS;
	#endif
	m_size = size;
	m_code = mmap(nullptr, size, PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS | additionalMapFlags, -1, 0);
	assert(m_code != MAP_FAILED);
#ifdef MEMFUNC_MMAP_REQUIRES_JIT_WRITE_PROTECT
	pthread_jit_write_protect_np(false);
#endif
	memcpy(m_code, code, size);
#ifdef MEMFUNC_MMAP_REQUIRES_JIT_WRITE_PROTECT
	pthread_jit_write_protect_np(true);
#endif
#elif defined(MEMFUNC_USE_WASM)
	m_wasmModule = emscripten::val::take_ownership(WasmCreateModule(reinterpret_cast<uintptr_t>(code), size));
	m_size = size;
	m_code = reinterpret_cast<void*>(WasmCreateFunction(m_wasmModule.as_handle()));
#endif
	ClearCache();
#if !defined(MEMFUNC_USE_WASM)
	assert((reinterpret_cast<uintptr_t>(m_code) & (BLOCK_ALIGN - 1)) == 0);
#endif
}

CMemoryFunction::~CMemoryFunction()
{
	Reset();
}

void CMemoryFunction::ClearCache()
{
#ifdef __APPLE__
	sys_icache_invalidate(m_code, m_size);
#elif defined(MEMFUNC_USE_MMAP)
	#if defined(__arm__) || defined(__aarch64__)
		__clear_cache(m_code, reinterpret_cast<uint8*>(m_code) + m_size);
	#endif
#endif
}

void CMemoryFunction::Reset()
{
	if(m_code != nullptr)
	{
#if defined(MEMFUNC_USE_WIN32)
		framework_aligned_free(m_code);
#elif defined(MEMFUNC_USE_MACHVM)
#if defined(MEMFUNC_IOS_RUNTIME_JIT_MODES)
		if(m_dualMapped)
		{
			if(!m_fromPool)
			{
				// LuckNoTXM fallback: RX was mmap'd, RW was vm_remap'd
				munmap(m_code, m_size);
				vm_deallocate(mach_task_self(), reinterpret_cast<vm_address_t>(m_codeRW), m_size);
			}
			// Pool sub-allocations (TXM or NoTXM pool) are not individually freed
		}
		else
		{
			vm_deallocate(mach_task_self(), reinterpret_cast<vm_address_t>(m_code), m_size);
		}
#else
		vm_deallocate(mach_task_self(), reinterpret_cast<vm_address_t>(m_code), m_size);
#endif
#elif defined(MEMFUNC_USE_MMAP)
		munmap(m_code, m_size);
#elif defined(MEMFUNC_USE_WASM)
		WasmDeleteFunction(reinterpret_cast<int>(m_code));
#endif
	}
	m_code = nullptr;
	m_size = 0;
#if defined(__APPLE__) && TARGET_OS_IPHONE
	m_codeRW       = nullptr;
	m_dualMapped   = false;
	m_fromPool = false;
#endif
#if defined(MEMFUNC_USE_WASM)
	m_wasmModule = emscripten::val();
#endif
}

bool CMemoryFunction::IsEmpty() const
{
	return m_code == nullptr;
}

CMemoryFunction& CMemoryFunction::operator =(CMemoryFunction&& rhs)
{
	Reset();
	std::swap(m_code, rhs.m_code);
	std::swap(m_size, rhs.m_size);
#if defined(__APPLE__) && TARGET_OS_IPHONE
	std::swap(m_codeRW, rhs.m_codeRW);
	std::swap(m_dualMapped, rhs.m_dualMapped);
	std::swap(m_fromPool, rhs.m_fromPool);
#endif
#if defined(MEMFUNC_USE_WASM)
	std::swap(m_wasmModule, rhs.m_wasmModule);
#endif
	return (*this);
}

void CMemoryFunction::operator()(void* context)
{
	typedef void (*FctType)(void*);
	auto fct = reinterpret_cast<FctType>(m_code);
	fct(context);
}

void* CMemoryFunction::GetCode() const
{
	return m_code;
}

void* CMemoryFunction::GetCodeRW() const
{
#if defined(__APPLE__) && TARGET_OS_IPHONE
	if(m_dualMapped && m_codeRW)
	{
		return m_codeRW;
	}
#endif
	return m_code;
}

size_t CMemoryFunction::GetSize() const
{
	return m_size;
}

void CMemoryFunction::BeginModify()
{
#if defined(MEMFUNC_USE_MACHVM) && defined(MEMFUNC_MACHVM_STRICT_PROTECTION)
#if defined(MEMFUNC_IOS_RUNTIME_JIT_MODES)
	if(!m_dualMapped)
	{
		kern_return_t result = vm_protect(mach_task_self(), reinterpret_cast<vm_address_t>(m_code), m_size, 0, VM_PROT_READ | VM_PROT_WRITE);
		assert(result == 0);
	}
	// Dual-mapped: RW alias is always writable, no vm_protect needed
#else
	kern_return_t result = vm_protect(mach_task_self(), reinterpret_cast<vm_address_t>(m_code), m_size, 0, VM_PROT_READ | VM_PROT_WRITE);
	assert(result == 0);
#endif
#elif defined(MEMFUNC_USE_MMAP) && defined(MEMFUNC_MMAP_REQUIRES_JIT_WRITE_PROTECT)
	pthread_jit_write_protect_np(false);
#endif
}

void CMemoryFunction::EndModify()
{
#if defined(MEMFUNC_USE_MACHVM) && defined(MEMFUNC_MACHVM_STRICT_PROTECTION)
#if defined(MEMFUNC_IOS_RUNTIME_JIT_MODES)
	if(!m_dualMapped)
	{
		kern_return_t result = vm_protect(mach_task_self(), reinterpret_cast<vm_address_t>(m_code), m_size, 0, VM_PROT_READ | VM_PROT_EXECUTE);
		assert(result == 0);
	}
	// Dual-mapped: RX alias is always executable, no vm_protect needed
#else
	kern_return_t result = vm_protect(mach_task_self(), reinterpret_cast<vm_address_t>(m_code), m_size, 0, VM_PROT_READ | VM_PROT_EXECUTE);
	assert(result == 0);
#endif
#elif defined(MEMFUNC_USE_MMAP) && defined(MEMFUNC_MMAP_REQUIRES_JIT_WRITE_PROTECT)
	pthread_jit_write_protect_np(true);
#endif
	ClearCache();
}

CMemoryFunction CMemoryFunction::CreateInstance()
{
#if defined(MEMFUNC_USE_WASM)
	CMemoryFunction result;
	result.m_wasmModule = m_wasmModule;
	result.m_size = m_size;
	result.m_code = reinterpret_cast<void*>(WasmCreateFunction(m_wasmModule.as_handle()));
	return result;
#else
	return CMemoryFunction(GetCode(), GetSize());
#endif
}
