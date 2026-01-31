#pragma once

#include "../GSHandler.h"
#include "../GsCachedArea.h"
#include "../GsTextureCache.h"

#ifdef __OBJC__
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#else
typedef void* id;
#endif

// Forward declarations for Objective-C types when compiled as C++
#ifndef __OBJC__
typedef void* MTLDeviceRef;
typedef void* MTLCommandQueueRef;
typedef void* MTLRenderPipelineStateRef;
typedef void* MTLBufferRef;
typedef void* MTLTextureRef;
typedef void* MTLDepthStencilStateRef;
typedef void* MTLSamplerStateRef;
typedef void* MTLLibraryRef;
#endif

class CGSH_Metal : public CGSHandler
{
public:
	CGSH_Metal();
	virtual ~CGSH_Metal() = default;

	void SetPresentationParams(const PRESENTATION_PARAMS&) override;
	uint8* GetRam() const override;

	void ProcessHostToLocalTransfer() override;
	void ProcessLocalToHostTransfer() override;
	void ProcessLocalToLocalTransfer() override;
	void ProcessClutTransfer(uint32, uint32) override;

protected:
	void InitializeImpl() override;
	void ReleaseImpl() override;
	void ResetImpl() override;
	void NotifyPreferencesChangedImpl() override;
	void FlipImpl(const DISPLAY_INFO&) override;
	void MarkNewFrame() override;
	void WriteRegisterImpl(uint8, uint64) override;
	void BeginTransferWrite() override;
	void TransferWrite(const uint8*, uint32) override;
	void SyncCLUT(const TEX0&) override;

	virtual void PresentBackbuffer() = 0;

	// Metal objects - stored as void* for C++ compatibility, cast in .mm
#ifdef __OBJC__
	id<MTLDevice> m_device;
	id<MTLCommandQueue> m_commandQueue;
	id<MTLLibrary> m_library;

	// Render pipeline states
	id<MTLRenderPipelineState> m_drawPipelineFlat;
	id<MTLRenderPipelineState> m_drawPipelineTextured;
	id<MTLRenderPipelineState> m_presentPipeline;

	// Depth/stencil states
	id<MTLDepthStencilState> m_depthLessEqual;
	id<MTLDepthStencilState> m_depthAlways;
	id<MTLDepthStencilState> m_depthDisabled;

	// Sampler states
	id<MTLSamplerState> m_samplerNearest;
	id<MTLSamplerState> m_samplerBilinear;

	// GS memory buffer (4MB)
	id<MTLBuffer> m_gsMemoryBuffer;

	// CLUT buffer
	id<MTLBuffer> m_clutBuffer;

	// Swizzle table textures
	id<MTLTexture> m_swizzleTablePSMCT32;
	id<MTLTexture> m_swizzleTablePSMCT16;
	id<MTLTexture> m_swizzleTablePSMT8;
	id<MTLTexture> m_swizzleTablePSMT4;

	// Present textures (render targets for the two display layers)
	id<MTLTexture> m_presentColorTexture;
	id<MTLTexture> m_presentDepthTexture;

	// Vertex buffer for primitives
	id<MTLBuffer> m_vertexBuffer;

	// Current drawable
	id<CAMetalDrawable> m_currentDrawable;

	// Presentation params
	CAMetalLayer* m_metalLayer;
#else
	void* m_device;
	void* m_commandQueue;
	void* m_library;
	void* m_drawPipelineFlat;
	void* m_drawPipelineTextured;
	void* m_presentPipeline;
	void* m_depthLessEqual;
	void* m_depthAlways;
	void* m_depthDisabled;
	void* m_samplerNearest;
	void* m_samplerBilinear;
	void* m_gsMemoryBuffer;
	void* m_clutBuffer;
	void* m_swizzleTablePSMCT32;
	void* m_swizzleTablePSMCT16;
	void* m_swizzleTablePSMT8;
	void* m_swizzleTablePSMT4;
	void* m_presentColorTexture;
	void* m_presentDepthTexture;
	void* m_vertexBuffer;
	void* m_currentDrawable;
	void* m_metalLayer;
#endif

private:
	// Vertex structure for Metal rendering
	struct MetalVertex
	{
		float position[4]; // x, y, z, w
		float texcoord[2]; // s, t
		float color[4];    // r, g, b, a
		float fog;
	};

	enum
	{
		MAX_VERTICES = 65536,
		CLUT_CACHE_SIZE = 32,
		GS_RAM_SIZE = 0x00400000, // 4MB
		VERTEX_BUFFER_SIZE = MAX_VERTICES * sizeof(MetalVertex),
	};

	struct CLUTKEY
	{
		uint32 idx4 : 1;
		uint32 cbp : 14;
		uint32 cpsm : 4;
		uint32 csm : 1;
		uint32 csa : 5;
		uint32 cbw : 6;
		uint32 reserved : 1;
	};

	void CreateDevice();
	void CreatePipelineStates();
	void CreateDepthStencilStates();
	void CreateSamplerStates();
	void CreateBuffers();
	void CreateSwizzleTables();
	void CreatePresentRenderTargets(uint32 width, uint32 height);

	void ProcessPrim(uint64);
	void VertexKick(uint8, uint64);
	void SetRenderingContext(uint64);

	void Prim_Point();
	void Prim_Line();
	void Prim_Triangle();
	void Prim_Sprite();

	void FlushVertices();
	void DoPresent(const DISPLAY_INFO&);

	void UploadGSMemory();

	// Draw context
	VERTEX m_vtxBuffer[3];
	uint32 m_vtxCount = 0;
	bool m_pendingPrim = false;
	uint64 m_pendingPrimValue = 0;
	uint32 m_primitiveType = 0;
	PRMODE m_primitiveMode;
	uint32 m_fbBasePtr = 0;
	float m_primOfsX = 0;
	float m_primOfsY = 0;
	uint32 m_texWidth = 0;
	uint32 m_texHeight = 0;
	std::vector<uint8> m_xferBuffer;

	// Vertex accumulation
	MetalVertex* m_mappedVertices = nullptr;
	uint32 m_currentVertex = 0;

	// Memory cache
	uint8* m_memoryCache = nullptr;

	// Presentation
	uint32 m_presentWidth = 0;
	uint32 m_presentHeight = 0;

	bool m_depthTestingEnabled = true;
	bool m_alphaBlendingEnabled = true;
	bool m_alphaTestingEnabled = true;

	CLUTKEY m_clutStates[CLUT_CACHE_SIZE];
	uint32 m_nextClutCacheIndex = 0;
};
