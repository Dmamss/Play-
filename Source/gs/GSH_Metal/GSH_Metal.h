#pragma once

#include "../GSHandler.h"
#include "../GsPixelFormats.h"

#ifdef __OBJC__
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <dispatch/dispatch.h>
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
	void SyncCLUT(const TEX0&) override;

	virtual void PresentBackbuffer() = 0;

	// Constants - must be defined before member variables that use them
	enum
	{
		MAX_VERTICES = 65536,
		CLUT_CACHE_SIZE = 32,
		GS_RAM_SIZE = 0x00400000,                               // 4MB
		GS_PAGE_SIZE = 0x2000,                                  // 8KB per page
		GS_PAGE_COUNT = GS_RAM_SIZE / GS_PAGE_SIZE,             // 512 pages
		VERTEX_BUFFER_SIZE = MAX_VERTICES * sizeof(float) * 12, // Approximate size
		MAX_INFLIGHT_FRAMES = 3,
	};

	// Metal objects - stored as void* for C++ compatibility, cast in .mm
#ifdef __OBJC__
	id<MTLDevice> m_device;
	id<MTLCommandQueue> m_commandQueue;
	id<MTLLibrary> m_library;

	// Render pipeline states
	id<MTLRenderPipelineState> m_drawPipelineFlat;
	id<MTLRenderPipelineState> m_drawPipelineTextured;
	id<MTLRenderPipelineState> m_drawPipelineFlatFBFetch;     // Framebuffer fetch variant
	id<MTLRenderPipelineState> m_drawPipelineTexturedFBFetch; // Framebuffer fetch variant
	id<MTLRenderPipelineState> m_presentPipeline;
	id<MTLComputePipelineState> m_localTransferPipeline; // GPU local-to-local transfer
	bool m_supportsFramebufferFetch;

	// Depth/stencil states
	id<MTLDepthStencilState> m_depthStateNever;
	id<MTLDepthStencilState> m_depthStateAlways;
	id<MTLDepthStencilState> m_depthStateGEqual;
	id<MTLDepthStencilState> m_depthStateGreater;
	id<MTLDepthStencilState> m_depthDisabledWrite;
	id<MTLDepthStencilState> m_depthDisabledNoWrite;

	// Sampler states
	id<MTLSamplerState> m_samplerNearest;
	id<MTLSamplerState> m_samplerBilinear;

	// GS memory buffer (4MB)
	id<MTLBuffer> m_gsMemoryBuffer;

	// CLUT buffer (256 entries * 4 bytes per cache slot)
	id<MTLBuffer> m_clutBuffer;

	// Swizzle table buffers
	id<MTLBuffer> m_swizzleTablePSMCT32;
	id<MTLBuffer> m_swizzleTablePSMCT16;
	id<MTLBuffer> m_swizzleTablePSMT8;

	// Present textures (render targets)
	id<MTLTexture> m_presentColorTexture;
	id<MTLTexture> m_presentDepthTexture;

	// Triple-buffered vertex buffers for primitives
	id<MTLBuffer> m_vertexBuffers[MAX_INFLIGHT_FRAMES];
	uint32 m_currentBufferIndex;

	// Triple-buffered uniform buffers for draw calls
	id<MTLBuffer> m_drawUniformBuffers[MAX_INFLIGHT_FRAMES];

	// Current drawable
	id<CAMetalDrawable> m_currentDrawable;

	// Presentation params
	CAMetalLayer* m_metalLayer;

	// Frame-level command buffer and render encoder (1 per frame, not per draw)
	id<MTLCommandBuffer> m_frameCommandBuffer;
	id<MTLRenderCommandEncoder> m_frameRenderEncoder;

	// Triple-buffering semaphore
	dispatch_semaphore_t m_inflightSemaphore;
#else
	void* m_device;
	void* m_commandQueue;
	void* m_library;
	void* m_drawPipelineFlat;
	void* m_drawPipelineTextured;
	void* m_drawPipelineFlatFBFetch;
	void* m_drawPipelineTexturedFBFetch;
	void* m_presentPipeline;
	void* m_localTransferPipeline;
	bool m_supportsFramebufferFetch;
	void* m_depthStateNever;
	void* m_depthStateAlways;
	void* m_depthStateGEqual;
	void* m_depthStateGreater;
	void* m_depthDisabledWrite;
	void* m_depthDisabledNoWrite;
	void* m_samplerNearest;
	void* m_samplerBilinear;
	void* m_gsMemoryBuffer;
	void* m_clutBuffer;
	void* m_swizzleTablePSMCT32;
	void* m_swizzleTablePSMCT16;
	void* m_swizzleTablePSMT8;
	void* m_presentColorTexture;
	void* m_presentDepthTexture;
	void* m_vertexBuffers[3];
	uint32 m_currentBufferIndex;
	void* m_drawUniformBuffers[3];
	void* m_currentDrawable;
	void* m_metalLayer;
	void* m_frameCommandBuffer;
	void* m_frameRenderEncoder;
	void* m_inflightSemaphore;
	void* m_boundPipelineState;
	void* m_boundDepthStencilState;
	struct
	{
		uint64 x, y, width, height;
	} m_boundScissorRect;
#endif

private:
	// Vertex structure for Metal rendering
	struct MetalVertex
	{
		float position[4]; // x, y, z, w
		float texcoord[2]; // u, v
		float color[4];    // r, g, b, a
		float fog;
		float padding;
	};

	// Transfer parameters for GPU compute kernel
	struct TransferParams
	{
		uint32 srcBufPtr;
		uint32 srcBufWidth;
		uint32 dstBufPtr;
		uint32 dstBufWidth;
		uint32 srcX;
		uint32 srcY;
		uint32 dstX;
		uint32 dstY;
		uint32 width;
		uint32 height;
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
	void PrecompileShaders();

	void ProcessPrim(uint64);
	void VertexKick(uint8, uint64);
	void SetRenderingContext(uint64);

	void Prim_Point();
	void Prim_Line();
	void Prim_Triangle();
	void Prim_Sprite();

	void EmitVertex(const VERTEX& vtx, float screenW, float screenH);

	void FlushVertices();
	void DoPresent(const DISPLAY_INFO&);

	void UploadGSMemory();
	void UploadDirtyPages();
	void MarkPagesDirty(uint32 startAddr, uint32 size);
	void MarkAllPagesDirty();
	void ClearDirtyPages();
	bool HasDirtyPages() const;

	// Frame-level encoder management
	void EnsureFrameCommandBuffer();
	void EnsureFrameRenderEncoder();
	void EndFrameRenderEncoder();

	CLUTKEY MakeCachedClutKey(const TEX0&) const;
	int32 FindCachedClut(const CLUTKEY&) const;

	// Draw context
	VERTEX m_vtxBuffer[3];
	uint32 m_vtxCount = 0;
	bool m_pendingPrim = false;
	uint64 m_pendingPrimValue = 0;
	uint32 m_primitiveType = 0;
	PRMODE m_primitiveMode;
	uint32 m_fbBasePtr = 0;
	uint32 m_fbWidth = 0;
	float m_primOfsX = 0;
	float m_primOfsY = 0;
	uint32 m_texBasePtr = 0;
	uint32 m_texBufWidth = 0;
	uint32 m_texWidth = 0;
	uint32 m_texHeight = 0;
	uint32 m_texPsm = 0;
	uint32 m_texCLUTPtr = 0;
	uint32 m_texCLUTPsm = 0;
	uint32 m_texFunction = 0;

	// Vertex accumulation
	MetalVertex* m_mappedVertices = nullptr;
	uint32 m_currentVertex = 0;
	bool m_drawIsTextured = false;

	// Memory cache
	uint8* m_memoryCache = nullptr;

	// Presentation
	uint32 m_presentWidth = 0;
	uint32 m_presentHeight = 0;

	// Rendering state from GS registers
	uint32 m_depthTestMethod = DEPTH_TEST_ALWAYS;
	bool m_depthWriteEnabled = true;
	bool m_depthEnabled = false;
	uint32 m_alphaTestMethod = ALPHA_TEST_ALWAYS;
	uint32 m_alphaTestRef = 0;
	uint32 m_alphaTestFail = ALPHA_TEST_FAIL_KEEP;
	bool m_alphaTestEnabled = false;
	uint32 m_scissorLeft = 0;
	uint32 m_scissorTop = 0;
	uint32 m_scissorRight = 0;
	uint32 m_scissorBottom = 0;

	// Alpha blending
	uint32 m_alphaA = 0;
	uint32 m_alphaB = 0;
	uint32 m_alphaC = 0;
	uint32 m_alphaD = 0;
	uint32 m_alphaFix = 0;
	bool m_useFramebufferFetch = false;     // True when blend mode requires FB fetch
	bool m_accurateBlendingEnabled = true;  // User preference for accurate PS2 blending
	bool m_precompileShadersEnabled = true; // User preference for shader pre-compilation

	// Fog
	float m_fogR = 0;
	float m_fogG = 0;
	float m_fogB = 0;

	// Screen dimensions (from display register)
	float m_screenWidth = 640.0f;
	float m_screenHeight = 448.0f;

	// Frame tracking
	bool m_frameClearedThisFrame = false;

	// GPU state tracking to avoid redundant bindings
	id<MTLRenderPipelineState> m_boundPipelineState;
	id<MTLDepthStencilState> m_boundDepthStencilState;
	MTLScissorRect m_boundScissorRect;

	// Dirty page tracking (512 pages, 8KB each)
	// Using 8 x 64-bit words = 512 bits for the bitmap
	uint64 m_dirtyPageBitmap[8] = {0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF,
	                               0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF,
	                               0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF,
	                               0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF};

	CLUTKEY m_clutStates[CLUT_CACHE_SIZE];
	uint32 m_nextClutCacheIndex = 0;
};
