#pragma once

#include "Types.h"

#if defined(__APPLE__)
#include "TargetConditionals.h"
#endif

#if defined(__EMSCRIPTEN__)
#include <emscripten/bind.h>
#endif

class CMemoryFunction
{
public:
	CMemoryFunction();
	CMemoryFunction(const void*, size_t);
	CMemoryFunction(const CMemoryFunction&) = delete;
	CMemoryFunction(CMemoryFunction&&);

	virtual ~CMemoryFunction();

	bool IsEmpty() const;

	CMemoryFunction& operator=(const CMemoryFunction&) = delete;

	CMemoryFunction& operator=(CMemoryFunction&&);
	void operator()(void*);

	void* GetCode() const;
	void* GetCodeRW() const;
	size_t GetSize() const;

	void BeginModify();
	void EndModify();

	CMemoryFunction CreateInstance();

private:
	void ClearCache();
	void Reset();

	void* m_code;
	size_t m_size;
#if defined(__APPLE__) && TARGET_OS_IPHONE
	void*  m_codeRW       = nullptr; // RW alias for dual-mapped modes
	bool   m_dualMapped    = false;  // true when RW and RX are separate mappings
	bool   m_fromPool      = false;  // true when sub-allocated from pooled region (TXM or NoTXM)
#endif
#if defined(__EMSCRIPTEN__)
	emscripten::val m_wasmModule;
#endif
};
