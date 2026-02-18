#import "GSH_Metal.h"
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <simd/simd.h>
#include "../GsPixelFormats.h"
#include "app_shared/AppConfig.h"
#include <algorithm>
#include <cstring>

// Metal-specific preference keys (matches ui_ios/PreferenceDefs.h)
#define PREF_METAL_ACCURATE_BLENDING "video.metal.accurateblending"
#define PREF_METAL_PRECOMPILE_SHADERS "video.metal.precompileshaders"

// Uniform buffer for draw calls
struct DrawUniforms
{
	simd_float2 texSize;
	simd_float2 screenSize;
	float alphaFix;
	uint32_t fbBasePtr;
	uint32_t fbWidth;
	uint32_t texBasePtr;
	uint32_t texBufWidth;
	uint32_t texPsm;
	uint32_t clutBasePtr;
	uint32_t clutPsm;
	uint32_t alphaRef;
	uint32_t alphaFunc;
	uint32_t texFunction;
	uint32_t alphaTestEnabled;
	simd_float3 fogColor;
	uint32_t fogEnabled;
};

// Extended uniforms for framebuffer fetch (PS2 alpha blend)
struct FBFetchUniforms
{
	simd_float2 texSize;
	simd_float2 screenSize;
	float alphaFix;
	uint32_t fbBasePtr;
	uint32_t fbWidth;
	uint32_t texBasePtr;
	uint32_t texBufWidth;
	uint32_t texPsm;
	uint32_t clutBasePtr;
	uint32_t clutPsm;
	uint32_t alphaRef;
	uint32_t alphaFunc;
	uint32_t texFunction;
	uint32_t alphaTestEnabled;
	simd_float3 fogColor;
	uint32_t fogEnabled;
	// PS2 alpha blend parameters
	uint32_t alphaA;
	uint32_t alphaB;
	uint32_t alphaC;
	uint32_t alphaD;
};

// Uniform buffer for present pass
struct PresentUniforms
{
	simd_float2 srcSize;
	simd_float2 dstSize;
	uint32_t fbPtr;
	uint32_t fbWidth;
	uint32_t fbPsm;
};

CGSH_Metal::CGSH_Metal()
    : m_device(nil)
    , m_commandQueue(nil)
    , m_library(nil)
    , m_drawPipelineFlat(nil)
    , m_drawPipelineTextured(nil)
    , m_drawPipelineFlatFBFetch(nil)
    , m_drawPipelineTexturedFBFetch(nil)
    , m_presentPipeline(nil)
    , m_supportsFramebufferFetch(false)
    , m_depthStateNever(nil)
    , m_depthStateAlways(nil)
    , m_depthStateGEqual(nil)
    , m_depthStateGreater(nil)
    , m_depthDisabledWrite(nil)
    , m_depthDisabledNoWrite(nil)
    , m_samplerNearest(nil)
    , m_samplerBilinear(nil)
    , m_gsMemoryBuffer(nil)
    , m_clutBuffer(nil)
    , m_swizzleTablePSMCT32(nil)
    , m_swizzleTablePSMCT16(nil)
    , m_swizzleTablePSMT8(nil)
    , m_presentColorTexture(nil)
    , m_presentDepthTexture(nil)
    , m_vertexBuffers{nil, nil, nil}
    , m_currentBufferIndex(0)
    , m_drawUniformBuffers{nil, nil, nil}
    , m_currentDrawable(nil)
    , m_metalLayer(nil)
    , m_frameCommandBuffer(nil)
    , m_frameRenderEncoder(nil)
    , m_inflightSemaphore(nil)
    , m_boundPipelineState(nil)
    , m_boundDepthStencilState(nil)
    , m_boundScissorRect{0, 0, 0, 0}
    , m_boundVertexBuffer(nil)
    , m_boundFragmentBuffers{nil, nil, nil, nil, nil, nil}
    , m_boundSamplerState(nil)
    , m_texturedStateSet(false)
{
	memset(&m_clutStates, 0, sizeof(m_clutStates));
	memset(&m_primitiveMode, 0, sizeof(m_primitiveMode));
}

uint8* CGSH_Metal::GetRam() const
{
	return m_memoryCache;
}

void CGSH_Metal::SetPresentationParams(const PRESENTATION_PARAMS& params)
{
	CGSHandler::SetPresentationParams(params);
	m_presentWidth = params.windowWidth;
	m_presentHeight = params.windowHeight;
}

void CGSH_Metal::InitializeImpl()
{
	// Read user preferences first
	m_accurateBlendingEnabled = CAppConfig::GetInstance().GetPreferenceBoolean(PREF_METAL_ACCURATE_BLENDING);
	m_precompileShadersEnabled = CAppConfig::GetInstance().GetPreferenceBoolean(PREF_METAL_PRECOMPILE_SHADERS);

	CreateDevice();
	CreateBuffers();
	CreateSwizzleTables();
	CreatePipelineStates();
	CreateDepthStencilStates();
	CreateSamplerStates();

	// Pre-compile all shader variants if enabled (reduces runtime stuttering)
	if(m_precompileShadersEnabled)
	{
		PrecompileShaders();
	}

	m_inflightSemaphore = dispatch_semaphore_create(MAX_INFLIGHT_FRAMES);

	m_memoryCache = new uint8[GS_RAM_SIZE];
	memset(m_memoryCache, 0, GS_RAM_SIZE);
}

void CGSH_Metal::ReleaseImpl()
{
	EndFrameRenderEncoder();
	if(m_frameCommandBuffer)
	{
		[m_frameCommandBuffer commit];
		[m_frameCommandBuffer waitUntilCompleted];
		m_frameCommandBuffer = nil;
	}

	m_drawPipelineFlat = nil;
	m_drawPipelineTextured = nil;
	m_drawPipelineFlatFBFetch = nil;
	m_drawPipelineTexturedFBFetch = nil;
	m_presentPipeline = nil;
	m_depthStateNever = nil;
	m_depthStateAlways = nil;
	m_depthStateGEqual = nil;
	m_depthStateGreater = nil;
	m_depthDisabledWrite = nil;
	m_depthDisabledNoWrite = nil;
	m_samplerNearest = nil;
	m_samplerBilinear = nil;
	m_gsMemoryBuffer = nil;
	m_clutBuffer = nil;
	m_swizzleTablePSMCT32 = nil;
	m_swizzleTablePSMCT16 = nil;
	m_swizzleTablePSMT8 = nil;
	m_presentColorTexture = nil;
	m_presentDepthTexture = nil;
	for(int i = 0; i < MAX_INFLIGHT_FRAMES; i++)
	{
		m_vertexBuffers[i] = nil;
		m_drawUniformBuffers[i] = nil;
	}
	m_currentDrawable = nil;
	m_library = nil;
	m_commandQueue = nil;
	m_device = nil;

	delete[] m_memoryCache;
	m_memoryCache = nullptr;
}

void CGSH_Metal::ResetImpl()
{
	EndFrameRenderEncoder();
	if(m_frameCommandBuffer)
	{
		[m_frameCommandBuffer commit];
		[m_frameCommandBuffer waitUntilCompleted];
		m_frameCommandBuffer = nil;
	}

	m_vtxCount = 0;
	m_pendingPrim = false;
	m_currentVertex = 0;
	m_nextClutCacheIndex = 0;
	m_drawIsTextured = false;
	m_primitiveType = PRIM_INVALID;
	m_frameClearedThisFrame = false;
	m_currentBufferIndex = 0;
	if(m_vertexBuffers[0])
	{
		m_mappedVertices = static_cast<MetalVertex*>([m_vertexBuffers[0] contents]);
	}
	MarkAllPagesDirty();

	memset(&m_clutStates, 0, sizeof(m_clutStates));
	memset(&m_primitiveMode, 0, sizeof(m_primitiveMode));

	if(m_memoryCache)
	{
		memset(m_memoryCache, 0, GS_RAM_SIZE);
	}

	CGSHandler::ResetImpl();
}

void CGSH_Metal::NotifyPreferencesChangedImpl()
{
	CGSHandler::NotifyPreferencesChangedImpl();

	// Read Metal-specific preferences
	m_accurateBlendingEnabled = CAppConfig::GetInstance().GetPreferenceBoolean(PREF_METAL_ACCURATE_BLENDING);
}

void CGSH_Metal::CreateDevice()
{
	m_device = MTLCreateSystemDefaultDevice();
	assert(m_device != nil);

	m_commandQueue = [m_device newCommandQueue];
	assert(m_commandQueue != nil);

	// Check for framebuffer fetch support (Apple GPU family 4+, A11 and later)
	// This enables accurate PS2 alpha blending without extra render passes
	// Note: supportsFamily: requires iOS 13.0+
	m_supportsFramebufferFetch = false;
	if(@available(iOS 13.0, macOS 10.15, *))
	{
		// Apple family 4 = A11 and later (iPhone 8/X and newer)
		if([m_device supportsFamily:MTLGPUFamilyApple4])
		{
			m_supportsFramebufferFetch = true;
			NSLog(@"[GSH_Metal] Framebuffer fetch supported (Apple GPU family 4+)");
		}
	}

	NSLog(@"[GSH_Metal] Using device: %@", m_device.name);
}

void CGSH_Metal::CreateBuffers()
{
	// GS memory buffer (4MB shared)
	m_gsMemoryBuffer = [m_device newBufferWithLength:GS_RAM_SIZE
	                                         options:MTLResourceStorageModeShared];

	// CLUT buffer: 256 entries * 4 bytes * CLUT_CACHE_SIZE slots
	m_clutBuffer = [m_device newBufferWithLength:256 * sizeof(uint32_t) * CLUT_CACHE_SIZE
	                                     options:MTLResourceStorageModeShared];

	// Triple-buffered vertex buffers
	for(int i = 0; i < MAX_INFLIGHT_FRAMES; i++)
	{
		m_vertexBuffers[i] = [m_device newBufferWithLength:VERTEX_BUFFER_SIZE
		                                           options:MTLResourceStorageModeShared];
	}
	m_currentBufferIndex = 0;
	m_mappedVertices = static_cast<MetalVertex*>([m_vertexBuffers[0] contents]);

	// Triple-buffered uniform buffers for draw calls
	for(int i = 0; i < MAX_INFLIGHT_FRAMES; i++)
	{
		m_drawUniformBuffers[i] = [m_device newBufferWithLength:sizeof(DrawUniforms)
		                                                options:MTLResourceStorageModeShared];
	}
}

void CGSH_Metal::CreateSwizzleTables()
{
	// Build PSMCT32 page offset table
	{
		auto* offsets = CGsPixelFormats::CPixelIndexorPSMCT32::GetPageOffsets();
		uint32_t tableSize = CGsPixelFormats::STORAGEPSMCT32::PAGEHEIGHT * CGsPixelFormats::STORAGEPSMCT32::PAGEWIDTH * sizeof(uint32_t);
		m_swizzleTablePSMCT32 = [m_device newBufferWithBytes:offsets
		                                              length:tableSize
		                                             options:MTLResourceStorageModeShared];
	}

	// Build PSMCT16 page offset table
	{
		auto* offsets = CGsPixelFormats::CPixelIndexorPSMCT16::GetPageOffsets();
		uint32_t tableSize = CGsPixelFormats::STORAGEPSMCT16::PAGEHEIGHT * CGsPixelFormats::STORAGEPSMCT16::PAGEWIDTH * sizeof(uint32_t);
		m_swizzleTablePSMCT16 = [m_device newBufferWithBytes:offsets
		                                              length:tableSize
		                                             options:MTLResourceStorageModeShared];
	}

	// Build PSMT8 page offset table
	{
		auto* offsets = CGsPixelFormats::CPixelIndexorPSMT8::GetPageOffsets();
		uint32_t tableSize = CGsPixelFormats::STORAGEPSMT8::PAGEHEIGHT * CGsPixelFormats::STORAGEPSMT8::PAGEWIDTH * sizeof(uint32_t);
		m_swizzleTablePSMT8 = [m_device newBufferWithBytes:offsets
		                                            length:tableSize
		                                           options:MTLResourceStorageModeShared];
	}
}

void CGSH_Metal::CreatePipelineStates()
{
	NSError* error = nil;

	// Try loading pre-compiled metallib first (fastest startup)
	NSString* libPath = [[NSBundle mainBundle] pathForResource:@"GSH_MetalShaders" ofType:@"metallib"];
	if(libPath)
	{
		NSURL* libURL = [NSURL fileURLWithPath:libPath];
		m_library = [m_device newLibraryWithURL:libURL error:&error];
		if(m_library)
		{
			NSLog(@"[GSH_Metal] Loaded pre-compiled metallib");
		}
	}

	// Try default library (shaders compiled into app binary)
	if(!m_library)
	{
		m_library = [m_device newDefaultLibrary];
		if(m_library)
		{
			NSLog(@"[GSH_Metal] Loaded default Metal library");
		}
	}

	if(!m_library)
	{
		// Compile shaders from source as fallback
		NSString* shaderSource = @R"(
#include <metal_stdlib>
using namespace metal;

// ============================================================
// Vertex structures
// ============================================================
struct VertexIn {
    float4 position [[attribute(0)]];
    float2 texcoord [[attribute(1)]];
    float4 color    [[attribute(2)]];
    float  fog      [[attribute(3)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texcoord;
    float4 color;
    float  fog;
};

// ============================================================
// Draw uniforms
// ============================================================
struct DrawUniforms {
    float2 texSize;
    float2 screenSize;
    float alphaFix;
    uint fbBasePtr;
    uint fbWidth;
    uint texBasePtr;
    uint texBufWidth;
    uint texPsm;
    uint clutBasePtr;
    uint clutPsm;
    uint alphaRef;
    uint alphaFunc;
    uint texFunction;
    uint alphaTestEnabled;
    float3 fogColor;
    uint fogEnabled;
};

// ============================================================
// Swizzle helpers
// ============================================================
uint computeAddressPSMCT32(int x, int y, uint bufPtr, uint bufWidth,
                           constant uint* swizzleTable) {
    const uint pageWidth = 64;
    const uint pageHeight = 32;
    const uint pageSize = 8192;
    uint pagesPerRow = bufWidth / pageWidth;
    if(pagesPerRow == 0) pagesPerRow = 1;
    uint pageX = x / pageWidth;
    uint pageY = y / pageHeight;
    uint page = pageY * pagesPerRow + pageX;
    uint localX = x % pageWidth;
    uint localY = y % pageHeight;
    uint pageOffset = swizzleTable[localY * pageWidth + localX];
    uint address = bufPtr + page * pageSize + pageOffset;
    return address & 0x003FFFFF;
}

uint computeAddressPSMCT16(int x, int y, uint bufPtr, uint bufWidth,
                            constant uint* swizzleTable) {
    const uint pageWidth = 64;
    const uint pageHeight = 64;
    const uint pageSize = 8192;
    uint pagesPerRow = bufWidth / pageWidth;
    if(pagesPerRow == 0) pagesPerRow = 1;
    uint pageX = x / pageWidth;
    uint pageY = y / pageHeight;
    uint page = pageY * pagesPerRow + pageX;
    uint localX = x % pageWidth;
    uint localY = y % pageHeight;
    uint pageOffset = swizzleTable[localY * pageWidth + localX];
    uint address = bufPtr + page * pageSize + pageOffset;
    return address & 0x003FFFFF;
}

uint computeAddressPSMT8(int x, int y, uint bufPtr, uint bufWidth,
                          constant uint* swizzleTable) {
    const uint pageWidth = 128;
    const uint pageHeight = 64;
    const uint pageSize = 8192;
    uint pagesPerRow = bufWidth / pageWidth;
    if(pagesPerRow == 0) pagesPerRow = 1;
    uint pageX = x / pageWidth;
    uint pageY = y / pageHeight;
    uint page = pageY * pagesPerRow + pageX;
    uint localX = x % pageWidth;
    uint localY = y % pageHeight;
    uint pageOffset = swizzleTable[localY * pageWidth + localX];
    uint address = bufPtr + page * pageSize + pageOffset;
    return address & 0x003FFFFF;
}

uint readPixelPSMCT32(int x, int y, uint bufPtr, uint bufWidth,
                       constant uint* gsMemory, constant uint* swizzleTable) {
    uint addr = computeAddressPSMCT32(x, y, bufPtr, bufWidth, swizzleTable);
    uint wordAddr = addr / 4;
    if(wordAddr >= 1048576) return 0;
    return gsMemory[wordAddr];
}

uint readPixelPSMCT16(int x, int y, uint bufPtr, uint bufWidth,
                       constant uchar* gsMemoryBytes, constant uint* swizzleTable) {
    uint addr = computeAddressPSMCT16(x, y, bufPtr, bufWidth, swizzleTable);
    if(addr + 1 >= 4194304) return 0;
    return uint(gsMemoryBytes[addr]) | (uint(gsMemoryBytes[addr + 1]) << 8);
}

uint readPixelPSMT8(int x, int y, uint bufPtr, uint bufWidth,
                     constant uchar* gsMemoryBytes, constant uint* swizzleTable) {
    uint addr = computeAddressPSMT8(x, y, bufPtr, bufWidth, swizzleTable);
    if(addr >= 4194304) return 0;
    return uint(gsMemoryBytes[addr]);
}

float4 unpackColor32(uint pixel) {
    float4 c;
    c.r = float((pixel >>  0) & 0xFF) / 255.0;
    c.g = float((pixel >>  8) & 0xFF) / 255.0;
    c.b = float((pixel >> 16) & 0xFF) / 255.0;
    c.a = float((pixel >> 24) & 0xFF) / 128.0;
    return c;
}

float4 unpackColor16(uint pixel) {
    float4 c;
    c.r = float(((pixel >>  0) & 0x1F)) / 31.0;
    c.g = float(((pixel >>  5) & 0x1F)) / 31.0;
    c.b = float(((pixel >> 10) & 0x1F)) / 31.0;
    c.a = float((pixel >> 15) & 1);
    return c;
}

bool alphaTest(float alphaValue, uint alphaFunc, uint alphaRef) {
    uint aRef = alphaRef;
    uint aVal = uint(clamp(alphaValue * 255.0, 0.0, 255.0));
    switch(alphaFunc) {
        case 0: return false;
        case 1: return true;
        case 2: return aVal < aRef;
        case 3: return aVal <= aRef;
        case 4: return aVal == aRef;
        case 5: return aVal >= aRef;
        case 6: return aVal > aRef;
        case 7: return aVal != aRef;
        default: return true;
    }
}

// ============================================================
// Draw vertex shader
// ============================================================
vertex VertexOut vs_draw(VertexIn in [[stage_in]]) {
    VertexOut out;
    out.position = in.position;
    out.texcoord = in.texcoord;
    out.color = in.color;
    out.fog = in.fog;
    return out;
}

// ============================================================
// Fragment shader: flat (untextured)
// ============================================================
fragment float4 fs_draw_flat(VertexOut in [[stage_in]],
                              constant DrawUniforms& uniforms [[buffer(0)]]) {
    float4 color = in.color;
    if(uniforms.alphaTestEnabled != 0) {
        if(!alphaTest(color.a, uniforms.alphaFunc, uniforms.alphaRef)) {
            discard_fragment();
        }
    }
    if(uniforms.fogEnabled != 0) {
        float fogFactor = in.fog / 255.0;
        color.rgb = mix(uniforms.fogColor, color.rgb, fogFactor);
    }
    return color;
}

// ============================================================
// Fragment shader: textured
// ============================================================
fragment float4 fs_draw_textured(VertexOut in [[stage_in]],
                                  constant DrawUniforms& uniforms [[buffer(0)]],
                                  constant uint* gsMemory [[buffer(1)]],
                                  constant uint* clutData [[buffer(2)]],
                                  constant uint* swizzleTableCT32 [[buffer(3)]],
                                  constant uint* swizzleTableCT16 [[buffer(4)]],
                                  constant uint* swizzleTableT8 [[buffer(5)]]) {
    int2 texCoord = int2(in.texcoord);
    texCoord.x = clamp(texCoord.x, 0, int(uniforms.texSize.x) - 1);
    texCoord.y = clamp(texCoord.y, 0, int(uniforms.texSize.y) - 1);

    float4 texColor;
    constant uchar* gsMemBytes = reinterpret_cast<constant uchar*>(gsMemory);
    uint psm = uniforms.texPsm;

    if(psm == 0x00 || psm == 0x01) {
        uint pixel = readPixelPSMCT32(texCoord.x, texCoord.y,
                                       uniforms.texBasePtr, uniforms.texBufWidth,
                                       gsMemory, swizzleTableCT32);
        texColor = unpackColor32(pixel);
        if(psm == 0x01) texColor.a = 1.0;
    } else if(psm == 0x02 || psm == 0x0A) {
        uint pixel = readPixelPSMCT16(texCoord.x, texCoord.y,
                                       uniforms.texBasePtr, uniforms.texBufWidth,
                                       gsMemBytes, swizzleTableCT16);
        texColor = unpackColor16(pixel);
    } else if(psm == 0x13) {
        uint index = readPixelPSMT8(texCoord.x, texCoord.y,
                                     uniforms.texBasePtr, uniforms.texBufWidth,
                                     gsMemBytes, swizzleTableT8);
        uint clutEntry = clutData[index & 0xFF];
        texColor = unpackColor32(clutEntry);
    } else if(psm == 0x14) {
        uint index = readPixelPSMT8(texCoord.x / 2, texCoord.y,
                                     uniforms.texBasePtr, uniforms.texBufWidth,
                                     gsMemBytes, swizzleTableT8);
        if((texCoord.x & 1) == 0) {
            index = index & 0x0F;
        } else {
            index = (index >> 4) & 0x0F;
        }
        uint clutEntry = clutData[index];
        texColor = unpackColor32(clutEntry);
    } else if(psm == 0x1B) {
        uint pixel = readPixelPSMCT32(texCoord.x, texCoord.y,
                                       uniforms.texBasePtr, uniforms.texBufWidth,
                                       gsMemory, swizzleTableCT32);
        uint index = (pixel >> 24) & 0xFF;
        uint clutEntry = clutData[index];
        texColor = unpackColor32(clutEntry);
    } else if(psm == 0x24) {
        uint pixel = readPixelPSMCT32(texCoord.x, texCoord.y,
                                       uniforms.texBasePtr, uniforms.texBufWidth,
                                       gsMemory, swizzleTableCT32);
        uint index = (pixel >> 24) & 0x0F;
        uint clutEntry = clutData[index];
        texColor = unpackColor32(clutEntry);
    } else if(psm == 0x2C) {
        uint pixel = readPixelPSMCT32(texCoord.x, texCoord.y,
                                       uniforms.texBasePtr, uniforms.texBufWidth,
                                       gsMemory, swizzleTableCT32);
        uint index = (pixel >> 28) & 0x0F;
        uint clutEntry = clutData[index];
        texColor = unpackColor32(clutEntry);
    } else {
        uint addr = (uniforms.texBasePtr + (texCoord.y * uniforms.texBufWidth + texCoord.x) * 4) / 4;
        if(addr < 1048576) {
            texColor = unpackColor32(gsMemory[addr]);
        } else {
            texColor = float4(1, 0, 1, 1);
        }
    }

    float4 color;
    uint texFunc = uniforms.texFunction;
    if(texFunc == 0) {
        color = texColor * in.color;
    } else if(texFunc == 1) {
        color = texColor;
    } else if(texFunc == 2) {
        color.rgb = texColor.rgb * in.color.rgb + in.color.aaa;
        color.a = texColor.a + in.color.a;
    } else if(texFunc == 3) {
        color.rgb = texColor.rgb * in.color.rgb + in.color.aaa;
        color.a = texColor.a;
    } else {
        color = texColor * in.color;
    }

    if(uniforms.alphaTestEnabled != 0) {
        if(!alphaTest(color.a, uniforms.alphaFunc, uniforms.alphaRef)) {
            discard_fragment();
        }
    }
    if(uniforms.fogEnabled != 0) {
        float fogFactor = in.fog / 255.0;
        color.rgb = mix(uniforms.fogColor, color.rgb, fogFactor);
    }
    return color;
}

// ============================================================
// Present pass - simple texture blit (samples m_presentColorTexture)
// ============================================================
struct PresentVertexOut {
    float4 position [[position]];
    float2 texcoord;
};

vertex PresentVertexOut vs_present(uint vertexId [[vertex_id]]) {
    float2 positions[4] = {
        float2(-1, -1),
        float2( 1, -1),
        float2(-1,  1),
        float2( 1,  1)
    };
    float2 texcoords[4] = {
        float2(0, 1),
        float2(1, 1),
        float2(0, 0),
        float2(1, 0)
    };
    PresentVertexOut out;
    out.position = float4(positions[vertexId], 0, 1);
    out.texcoord = texcoords[vertexId];
    return out;
}

fragment float4 fs_present(PresentVertexOut in [[stage_in]],
                           texture2d<float> srcTexture [[texture(0)]],
                           sampler s [[sampler(0)]]) {
    return srcTexture.sample(s, in.texcoord);
}

// ============================================================
// Compute kernel for local-to-local transfers (GPU-accelerated)
// ============================================================
struct TransferParams {
    uint srcBufPtr;
    uint srcBufWidth;
    uint dstBufPtr;
    uint dstBufWidth;
    uint srcX;
    uint srcY;
    uint dstX;
    uint dstY;
    uint width;
    uint height;
};

kernel void cs_local_transfer(
    device uint* gsMemory [[buffer(0)]],
    constant uint* swizzleTableCT32 [[buffer(1)]],
    constant TransferParams& params [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if(gid.x >= params.width || gid.y >= params.height) return;

    int srcPosX = int(params.srcX + gid.x);
    int srcPosY = int(params.srcY + gid.y);
    int dstPosX = int(params.dstX + gid.x);
    int dstPosY = int(params.dstY + gid.y);

    // Read from source using swizzle table
    uint srcAddr = computeAddressPSMCT32(srcPosX, srcPosY, params.srcBufPtr, params.srcBufWidth, swizzleTableCT32);
    uint srcWordAddr = srcAddr / 4;
    uint pixel = (srcWordAddr < 1048576) ? gsMemory[srcWordAddr] : 0;

    // Write to destination using swizzle table
    uint dstAddr = computeAddressPSMCT32(dstPosX, dstPosY, params.dstBufPtr, params.dstBufWidth, swizzleTableCT32);
    uint dstWordAddr = dstAddr / 4;
    if(dstWordAddr < 1048576) {
        gsMemory[dstWordAddr] = pixel;
    }
}
)";

		MTLCompileOptions* options = [[MTLCompileOptions alloc] init];
		if(@available(iOS 15.0, *))
		{
			options.languageVersion = MTLLanguageVersion2_4;
		}
		m_library = [m_device newLibraryWithSource:shaderSource options:options error:&error];
		if(error)
		{
			NSLog(@"[GSH_Metal] Shader compilation error: %@", error);
		}
		else
		{
			NSLog(@"[GSH_Metal] Compiled shaders from source (slower startup)");
		}
	}

	assert(m_library != nil);

	// Create vertex descriptor
	MTLVertexDescriptor* vertexDesc = [[MTLVertexDescriptor alloc] init];
	vertexDesc.attributes[0].format = MTLVertexFormatFloat4; // position
	vertexDesc.attributes[0].offset = offsetof(MetalVertex, position);
	vertexDesc.attributes[0].bufferIndex = 0;
	vertexDesc.attributes[1].format = MTLVertexFormatFloat2; // texcoord
	vertexDesc.attributes[1].offset = offsetof(MetalVertex, texcoord);
	vertexDesc.attributes[1].bufferIndex = 0;
	vertexDesc.attributes[2].format = MTLVertexFormatFloat4; // color
	vertexDesc.attributes[2].offset = offsetof(MetalVertex, color);
	vertexDesc.attributes[2].bufferIndex = 0;
	vertexDesc.attributes[3].format = MTLVertexFormatFloat; // fog
	vertexDesc.attributes[3].offset = offsetof(MetalVertex, fog);
	vertexDesc.attributes[3].bufferIndex = 0;
	vertexDesc.layouts[0].stride = sizeof(MetalVertex);
	vertexDesc.layouts[0].stepRate = 1;
	vertexDesc.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

	// Flat draw pipeline
	{
		MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
		desc.label = @"GSH_Metal Flat Draw";
		desc.vertexFunction = [m_library newFunctionWithName:@"vs_draw"];
		desc.fragmentFunction = [m_library newFunctionWithName:@"fs_draw_flat"];
		desc.vertexDescriptor = vertexDesc;
		desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
		desc.colorAttachments[0].blendingEnabled = YES;
		desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
		desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
		desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
		m_drawPipelineFlat = [m_device newRenderPipelineStateWithDescriptor:desc error:&error];
		if(error) NSLog(@"[GSH_Metal] Draw flat pipeline error: %@", error);
	}

	// Textured draw pipeline
	{
		MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
		desc.label = @"GSH_Metal Textured Draw";
		desc.vertexFunction = [m_library newFunctionWithName:@"vs_draw"];
		desc.fragmentFunction = [m_library newFunctionWithName:@"fs_draw_textured"];
		desc.vertexDescriptor = vertexDesc;
		desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
		desc.colorAttachments[0].blendingEnabled = YES;
		desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
		desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
		desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
		m_drawPipelineTextured = [m_device newRenderPipelineStateWithDescriptor:desc error:&error];
		if(error) NSLog(@"[GSH_Metal] Draw textured pipeline error: %@", error);
	}

	// Framebuffer fetch pipelines (A11+ devices) - accurate PS2 alpha blending
	if(m_supportsFramebufferFetch)
	{
		id<MTLFunction> fbFetchFlatFunc = [m_library newFunctionWithName:@"fs_draw_flat_fbfetch"];
		id<MTLFunction> fbFetchTexturedFunc = [m_library newFunctionWithName:@"fs_draw_textured_fbfetch"];

		if(fbFetchFlatFunc && fbFetchTexturedFunc)
		{
			// Flat framebuffer fetch pipeline
			{
				MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
				desc.label = @"GSH_Metal Flat Draw (FB Fetch)";
				desc.vertexFunction = [m_library newFunctionWithName:@"vs_draw"];
				desc.fragmentFunction = fbFetchFlatFunc;
				desc.vertexDescriptor = vertexDesc;
				desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
				desc.colorAttachments[0].blendingEnabled = NO; // Blending done in shader
				desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
				m_drawPipelineFlatFBFetch = [m_device newRenderPipelineStateWithDescriptor:desc error:&error];
				if(error) NSLog(@"[GSH_Metal] Flat FB fetch pipeline error: %@", error);
			}

			// Textured framebuffer fetch pipeline
			{
				MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
				desc.label = @"GSH_Metal Textured Draw (FB Fetch)";
				desc.vertexFunction = [m_library newFunctionWithName:@"vs_draw"];
				desc.fragmentFunction = fbFetchTexturedFunc;
				desc.vertexDescriptor = vertexDesc;
				desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
				desc.colorAttachments[0].blendingEnabled = NO; // Blending done in shader
				desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
				m_drawPipelineTexturedFBFetch = [m_device newRenderPipelineStateWithDescriptor:desc error:&error];
				if(error) NSLog(@"[GSH_Metal] Textured FB fetch pipeline error: %@", error);
			}

			NSLog(@"[GSH_Metal] Framebuffer fetch pipelines created successfully");
		}
		else
		{
			NSLog(@"[GSH_Metal] FB fetch shader functions not found, disabling FB fetch");
			m_supportsFramebufferFetch = false;
		}
	}

	// Present pipeline - samples a texture, no depth
	{
		MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
		desc.label = @"GSH_Metal Present";
		desc.vertexFunction = [m_library newFunctionWithName:@"vs_present"];
		desc.fragmentFunction = [m_library newFunctionWithName:@"fs_present"];
		desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
		m_presentPipeline = [m_device newRenderPipelineStateWithDescriptor:desc error:&error];
		if(error) NSLog(@"[GSH_Metal] Present pipeline error: %@", error);
	}

	// Compute pipeline for local-to-local transfers (GPU-accelerated)
	{
		id<MTLFunction> transferFunc = [m_library newFunctionWithName:@"cs_local_transfer"];
		if(transferFunc)
		{
			m_localTransferPipeline = [m_device newComputePipelineStateWithFunction:transferFunc error:&error];
			if(error)
			{
				NSLog(@"[GSH_Metal] Local transfer compute pipeline error: %@", error);
				m_localTransferPipeline = nil;
			}
			else
			{
				NSLog(@"[GSH_Metal] GPU local transfer compute pipeline created");
			}
		}
		else
		{
			NSLog(@"[GSH_Metal] Local transfer compute function not found");
			m_localTransferPipeline = nil;
		}
	}
}

void CGSH_Metal::CreateDepthStencilStates()
{
	{
		MTLDepthStencilDescriptor* desc = [[MTLDepthStencilDescriptor alloc] init];
		desc.depthCompareFunction = MTLCompareFunctionNever;
		desc.depthWriteEnabled = NO;
		m_depthStateNever = [m_device newDepthStencilStateWithDescriptor:desc];
	}
	{
		MTLDepthStencilDescriptor* desc = [[MTLDepthStencilDescriptor alloc] init];
		desc.depthCompareFunction = MTLCompareFunctionAlways;
		desc.depthWriteEnabled = YES;
		m_depthStateAlways = [m_device newDepthStencilStateWithDescriptor:desc];
	}
	{
		MTLDepthStencilDescriptor* desc = [[MTLDepthStencilDescriptor alloc] init];
		desc.depthCompareFunction = MTLCompareFunctionGreaterEqual;
		desc.depthWriteEnabled = YES;
		m_depthStateGEqual = [m_device newDepthStencilStateWithDescriptor:desc];
	}
	{
		MTLDepthStencilDescriptor* desc = [[MTLDepthStencilDescriptor alloc] init];
		desc.depthCompareFunction = MTLCompareFunctionGreater;
		desc.depthWriteEnabled = YES;
		m_depthStateGreater = [m_device newDepthStencilStateWithDescriptor:desc];
	}
	{
		MTLDepthStencilDescriptor* desc = [[MTLDepthStencilDescriptor alloc] init];
		desc.depthCompareFunction = MTLCompareFunctionAlways;
		desc.depthWriteEnabled = YES;
		m_depthDisabledWrite = [m_device newDepthStencilStateWithDescriptor:desc];
	}
	{
		MTLDepthStencilDescriptor* desc = [[MTLDepthStencilDescriptor alloc] init];
		desc.depthCompareFunction = MTLCompareFunctionAlways;
		desc.depthWriteEnabled = NO;
		m_depthDisabledNoWrite = [m_device newDepthStencilStateWithDescriptor:desc];
	}
}

void CGSH_Metal::CreateSamplerStates()
{
	{
		MTLSamplerDescriptor* desc = [[MTLSamplerDescriptor alloc] init];
		desc.minFilter = MTLSamplerMinMagFilterNearest;
		desc.magFilter = MTLSamplerMinMagFilterNearest;
		desc.sAddressMode = MTLSamplerAddressModeRepeat;
		desc.tAddressMode = MTLSamplerAddressModeRepeat;
		m_samplerNearest = [m_device newSamplerStateWithDescriptor:desc];
	}
	{
		MTLSamplerDescriptor* desc = [[MTLSamplerDescriptor alloc] init];
		desc.minFilter = MTLSamplerMinMagFilterLinear;
		desc.magFilter = MTLSamplerMinMagFilterLinear;
		desc.sAddressMode = MTLSamplerAddressModeRepeat;
		desc.tAddressMode = MTLSamplerAddressModeRepeat;
		m_samplerBilinear = [m_device newSamplerStateWithDescriptor:desc];
	}
}

void CGSH_Metal::CreatePresentRenderTargets(uint32 width, uint32 height)
{
	if(width == 0 || height == 0) return;

	MTLTextureDescriptor* colorDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
	                                                                                     width:width
	                                                                                    height:height
	                                                                                 mipmapped:NO];
	colorDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	colorDesc.storageMode = MTLStorageModePrivate;
	m_presentColorTexture = [m_device newTextureWithDescriptor:colorDesc];

	MTLTextureDescriptor* depthDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
	                                                                                     width:width
	                                                                                    height:height
	                                                                                 mipmapped:NO];
	depthDesc.usage = MTLTextureUsageRenderTarget;
	depthDesc.storageMode = MTLStorageModePrivate;
	m_presentDepthTexture = [m_device newTextureWithDescriptor:depthDesc];
}

// ============================================================
// Frame-level command buffer and render encoder management
// Only 1 command buffer and 1 render encoder per frame.
// ============================================================

void CGSH_Metal::EnsureFrameCommandBuffer()
{
	if(m_frameCommandBuffer == nil)
	{
		m_frameCommandBuffer = [m_commandQueue commandBuffer];
		m_frameCommandBuffer.label = @"GSH_Metal Frame";
	}
}

void CGSH_Metal::EnsureFrameRenderEncoder()
{
	if(m_frameRenderEncoder != nil) return;

	EnsureFrameCommandBuffer();

	// Ensure render targets exist
	if(m_presentColorTexture == nil)
	{
		uint32 w = m_presentWidth > 0 ? m_presentWidth : (uint32)m_screenWidth;
		uint32 h = m_presentHeight > 0 ? m_presentHeight : (uint32)m_screenHeight;
		if(w == 0) w = 640;
		if(h == 0) h = 448;
		CreatePresentRenderTargets(w, h);
	}

	if(m_presentColorTexture == nil) return;

	// NOTE: Dirty pages are now uploaded in FlushVertices() before each draw,
	// so we don't need to upload here anymore. This allows us to keep the
	// encoder open across memory transfers for much better performance.

	MTLRenderPassDescriptor* renderPass = [MTLRenderPassDescriptor renderPassDescriptor];
	renderPass.colorAttachments[0].texture = m_presentColorTexture;
	renderPass.colorAttachments[0].storeAction = MTLStoreActionStore;
	renderPass.depthAttachment.texture = m_presentDepthTexture;
	renderPass.depthAttachment.storeAction = MTLStoreActionStore;

	// Clear on first use this frame, load on subsequent
	if(!m_frameClearedThisFrame)
	{
		renderPass.colorAttachments[0].loadAction = MTLLoadActionClear;
		renderPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
		renderPass.depthAttachment.loadAction = MTLLoadActionClear;
		renderPass.depthAttachment.clearDepth = 0.0;
		m_frameClearedThisFrame = true;
	}
	else
	{
		renderPass.colorAttachments[0].loadAction = MTLLoadActionLoad;
		renderPass.depthAttachment.loadAction = MTLLoadActionLoad;
	}

	m_frameRenderEncoder = [m_frameCommandBuffer renderCommandEncoderWithDescriptor:renderPass];
	m_frameRenderEncoder.label = @"GSH_Metal Draw";

	// Reset state tracking for new encoder
	m_boundPipelineState = nil;
	m_boundDepthStencilState = nil;
	m_boundScissorRect = {0, 0, 0, 0};
	m_boundVertexBuffer = nil;
	memset(m_boundFragmentBuffers, 0, sizeof(m_boundFragmentBuffers));
	m_boundSamplerState = nil;
	m_texturedStateSet = false;
}

void CGSH_Metal::EndFrameRenderEncoder()
{
	if(m_frameRenderEncoder != nil)
	{
		[m_frameRenderEncoder endEncoding];
		m_frameRenderEncoder = nil;
	}
}

void CGSH_Metal::MarkNewFrame()
{
	CGSHandler::MarkNewFrame();
}

// ============================================================
// WriteRegisterImpl
// ============================================================
void CGSH_Metal::WriteRegisterImpl(uint8 registerId, uint64 data)
{
	CGSHandler::WriteRegisterImpl(registerId, data);

	switch(registerId)
	{
	case GS_REG_PRIM:
		m_pendingPrim = true;
		m_pendingPrimValue = data;
		break;
	case GS_REG_XYZ2:
	case GS_REG_XYZ3:
	case GS_REG_XYZF2:
	case GS_REG_XYZF3:
		VertexKick(registerId, data);
		break;
	}
}

// ============================================================
// VertexKick
// ============================================================
void CGSH_Metal::VertexKick(uint8 registerId, uint64 data)
{
	if(m_pendingPrim)
	{
		m_pendingPrim = false;
		ProcessPrim(m_pendingPrimValue);
	}

	if(m_vtxCount == 0) return;

	bool drawingKick = (registerId == GS_REG_XYZ2) || (registerId == GS_REG_XYZF2);
	bool fog = (registerId == GS_REG_XYZF2) || (registerId == GS_REG_XYZF3);

	if(!m_drawEnabled) drawingKick = false;

	if(fog)
	{
		m_vtxBuffer[m_vtxCount - 1].position = data & 0x00FFFFFFFFFFFFFFULL;
		m_vtxBuffer[m_vtxCount - 1].rgbaq = m_nReg[GS_REG_RGBAQ];
		m_vtxBuffer[m_vtxCount - 1].uv = m_nReg[GS_REG_UV];
		m_vtxBuffer[m_vtxCount - 1].st = m_nReg[GS_REG_ST];
		m_vtxBuffer[m_vtxCount - 1].fog = static_cast<uint8>(data >> 56);
	}
	else
	{
		m_vtxBuffer[m_vtxCount - 1].position = data;
		m_vtxBuffer[m_vtxCount - 1].rgbaq = m_nReg[GS_REG_RGBAQ];
		m_vtxBuffer[m_vtxCount - 1].uv = m_nReg[GS_REG_UV];
		m_vtxBuffer[m_vtxCount - 1].st = m_nReg[GS_REG_ST];
		m_vtxBuffer[m_vtxCount - 1].fog = static_cast<uint8>(m_nReg[GS_REG_FOG] >> 56);
	}

	m_vtxCount--;

	if(m_vtxCount == 0)
	{
		if((m_nReg[GS_REG_PRMODECONT] & 1) != 0)
		{
			m_primitiveMode <<= m_nReg[GS_REG_PRIM];
		}
		else
		{
			m_primitiveMode <<= m_nReg[GS_REG_PRMODE];
		}

		if(drawingKick)
		{
			SetRenderingContext(m_primitiveMode);
		}

		switch(m_primitiveType)
		{
		case PRIM_POINT:
			if(drawingKick) Prim_Point();
			m_vtxCount = 1;
			break;
		case PRIM_LINE:
			if(drawingKick) Prim_Line();
			m_vtxCount = 2;
			break;
		case PRIM_LINESTRIP:
			if(drawingKick) Prim_Line();
			memcpy(&m_vtxBuffer[1], &m_vtxBuffer[0], sizeof(VERTEX));
			m_vtxCount = 1;
			break;
		case PRIM_TRIANGLE:
			if(drawingKick) Prim_Triangle();
			m_vtxCount = 3;
			break;
		case PRIM_TRIANGLESTRIP:
			if(drawingKick) Prim_Triangle();
			memcpy(&m_vtxBuffer[2], &m_vtxBuffer[1], sizeof(VERTEX));
			memcpy(&m_vtxBuffer[1], &m_vtxBuffer[0], sizeof(VERTEX));
			m_vtxCount = 1;
			break;
		case PRIM_TRIANGLEFAN:
			if(drawingKick) Prim_Triangle();
			memcpy(&m_vtxBuffer[1], &m_vtxBuffer[0], sizeof(VERTEX));
			m_vtxCount = 1;
			break;
		case PRIM_SPRITE:
			if(drawingKick) Prim_Sprite();
			m_vtxCount = 2;
			break;
		}
	}
}

// ============================================================
// ProcessPrim
// ============================================================
void CGSH_Metal::ProcessPrim(uint64 data)
{
	auto prim = make_convertible<PRIM>(data);

	unsigned int newPrimType = prim.nType;
	if(newPrimType != m_primitiveType && m_currentVertex > 0)
	{
		FlushVertices();
	}

	m_primitiveType = newPrimType;

	switch(m_primitiveType)
	{
	case PRIM_POINT:
		m_vtxCount = 1;
		break;
	case PRIM_LINE:
	case PRIM_LINESTRIP:
		m_vtxCount = 2;
		break;
	case PRIM_TRIANGLE:
	case PRIM_TRIANGLESTRIP:
	case PRIM_TRIANGLEFAN:
		m_vtxCount = 3;
		break;
	case PRIM_SPRITE:
		m_vtxCount = 2;
		break;
	default:
		m_vtxCount = 0;
		break;
	}
}

// ============================================================
// SetRenderingContext
// ============================================================
void CGSH_Metal::SetRenderingContext(uint64 primReg)
{
	auto prim = make_convertible<PRMODE>(primReg);
	unsigned int context = prim.nContext;

	auto offset = make_convertible<XYOFFSET>(m_nReg[GS_REG_XYOFFSET_1 + context]);
	m_primOfsX = offset.GetX();
	m_primOfsY = offset.GetY();

	auto frame = make_convertible<FRAME>(m_nReg[GS_REG_FRAME_1 + context]);
	m_fbBasePtr = frame.GetBasePtr();
	m_fbWidth = frame.GetWidth();

	auto zbuf = make_convertible<ZBUF>(m_nReg[GS_REG_ZBUF_1 + context]);
	m_depthWriteEnabled = (zbuf.nMask == 0);

	auto test = make_convertible<TEST>(m_nReg[GS_REG_TEST_1 + context]);
	m_depthEnabled = test.nDepthEnabled != 0;
	m_depthTestMethod = test.nDepthMethod;
	m_alphaTestEnabled = test.nAlphaEnabled != 0;
	m_alphaTestMethod = test.nAlphaMethod;
	m_alphaTestRef = test.nAlphaRef;
	m_alphaTestFail = test.nAlphaFail;

	auto alpha = make_convertible<ALPHA>(m_nReg[GS_REG_ALPHA_1 + context]);
	m_alphaA = alpha.nA;
	m_alphaB = alpha.nB;
	m_alphaC = alpha.nC;
	m_alphaD = alpha.nD;
	m_alphaFix = alpha.nFix;

	// Determine if we need framebuffer fetch for this blend mode
	// Use FB fetch when blend mode can't be expressed with standard blend factors
	// (e.g., when destination color is used in a complex way)
	// Only enabled if hardware supports it AND user has enabled accurate blending
	m_useFramebufferFetch = false;
	if(m_supportsFramebufferFetch && m_accurateBlendingEnabled && prim.nAlpha)
	{
		// Standard blend: Cs*As + Cd*(1-As) is A=0,B=1,C=0,D=1
		// If blend mode differs from standard, use FB fetch for accuracy
		bool isStandardBlend = (m_alphaA == 0 && m_alphaB == 1 && m_alphaC == 0 && m_alphaD == 1);
		bool isNoBlend = (m_alphaA == 0 && m_alphaB == 0 && m_alphaC == 0 && m_alphaD == 0);
		m_useFramebufferFetch = !isStandardBlend && !isNoBlend;
	}

	auto scissor = make_convertible<SCISSOR>(m_nReg[GS_REG_SCISSOR_1 + context]);
	m_scissorLeft = scissor.scax0;
	m_scissorTop = scissor.scay0;
	m_scissorRight = scissor.scax1;
	m_scissorBottom = scissor.scay1;

	if(prim.nTexture)
	{
		auto tex0 = make_convertible<TEX0>(m_nReg[GS_REG_TEX0_1 + context]);
		m_texBasePtr = tex0.GetBufPtr();
		m_texBufWidth = tex0.GetBufWidth();
		m_texWidth = tex0.GetWidth();
		m_texHeight = tex0.GetHeight();
		m_texPsm = tex0.nPsm;
		m_texCLUTPtr = tex0.GetCLUTPtr();
		m_texCLUTPsm = tex0.nCPSM;
		m_texFunction = tex0.nFunction;

		if(CGsPixelFormats::IsPsmIDTEX(m_texPsm))
		{
			SyncCLUT(tex0);
		}

		m_drawIsTextured = true;
	}
	else
	{
		m_drawIsTextured = false;
	}

	auto fogCol = make_convertible<FOGCOL>(m_nReg[GS_REG_FOGCOL]);
	m_fogR = (float)fogCol.nFCR / 255.0f;
	m_fogG = (float)fogCol.nFCG / 255.0f;
	m_fogB = (float)fogCol.nFCB / 255.0f;
}

// ============================================================
// EmitVertex
// ============================================================
void CGSH_Metal::EmitVertex(const VERTEX& vtx, float screenW, float screenH)
{
	if(m_currentVertex >= MAX_VERTICES)
	{
		FlushVertices();
	}

	auto& mv = m_mappedVertices[m_currentVertex++];

	auto xyz = make_convertible<XYZ>(vtx.position);
	float posX = xyz.GetX() - m_primOfsX;
	float posY = xyz.GetY() - m_primOfsY;
	float posZ = (float)xyz.nZ / 4294967296.0f;

	float x = posX / screenW * 2.0f - 1.0f;
	float y = -(posY / screenH * 2.0f - 1.0f);

	mv.position[0] = x;
	mv.position[1] = y;
	mv.position[2] = posZ;
	mv.position[3] = 1.0f;

	auto rgbaq = make_convertible<RGBAQ>(vtx.rgbaq);
	mv.color[0] = (float)rgbaq.nR / 255.0f;
	mv.color[1] = (float)rgbaq.nG / 255.0f;
	mv.color[2] = (float)rgbaq.nB / 255.0f;
	mv.color[3] = (float)rgbaq.nA / 128.0f;

	if(m_drawIsTextured)
	{
		if(m_primitiveMode.nUseUV)
		{
			auto uv = make_convertible<UV>(vtx.uv);
			mv.texcoord[0] = uv.GetU();
			mv.texcoord[1] = uv.GetV();
		}
		else
		{
			auto st = make_convertible<ST>(vtx.st);
			float q = rgbaq.nQ;
			if(q == 0.0f) q = 1.0f;
			mv.texcoord[0] = st.nS / q * (float)m_texWidth;
			mv.texcoord[1] = st.nT / q * (float)m_texHeight;
		}
	}
	else
	{
		mv.texcoord[0] = 0.0f;
		mv.texcoord[1] = 0.0f;
	}

	mv.fog = (float)vtx.fog;
	mv.padding = 0.0f;
}

// ============================================================
// Prim_Point
// ============================================================
void CGSH_Metal::Prim_Point()
{
	auto& vtx = m_vtxBuffer[0];
	float screenW = m_screenWidth;
	float screenH = m_screenHeight;

	EmitVertex(vtx, screenW, screenH);
	EmitVertex(vtx, screenW, screenH);
	EmitVertex(vtx, screenW, screenH);

	if(m_currentVertex >= 3)
	{
		m_mappedVertices[m_currentVertex - 2].position[0] += 2.0f / screenW;
		m_mappedVertices[m_currentVertex - 1].position[1] += 2.0f / screenH;
	}
}

// ============================================================
// Prim_Line
// ============================================================
void CGSH_Metal::Prim_Line()
{
	auto& vtx0 = m_vtxBuffer[1];
	auto& vtx1 = m_vtxBuffer[0];
	float screenW = m_screenWidth;
	float screenH = m_screenHeight;

	auto xyz0 = make_convertible<XYZ>(vtx0.position);
	auto xyz1 = make_convertible<XYZ>(vtx1.position);

	float x0 = xyz0.GetX() - m_primOfsX;
	float y0 = xyz0.GetY() - m_primOfsY;
	float x1 = xyz1.GetX() - m_primOfsX;
	float y1 = xyz1.GetY() - m_primOfsY;

	float dx = x1 - x0;
	float dy = y1 - y0;
	float len = sqrtf(dx * dx + dy * dy);
	if(len < 0.001f) len = 0.001f;

	float hw = 0.5f;
	float nx = -dy / len * hw;
	float ny = dx / len * hw;

	EmitVertex(vtx0, screenW, screenH);
	EmitVertex(vtx0, screenW, screenH);
	EmitVertex(vtx1, screenW, screenH);

	if(m_currentVertex >= 3)
	{
		float nxNDC = nx / screenW * 2.0f;
		float nyNDC = ny / screenH * 2.0f;
		m_mappedVertices[m_currentVertex - 3].position[0] += nxNDC;
		m_mappedVertices[m_currentVertex - 3].position[1] -= nyNDC;
		m_mappedVertices[m_currentVertex - 2].position[0] -= nxNDC;
		m_mappedVertices[m_currentVertex - 2].position[1] += nyNDC;
	}

	EmitVertex(vtx0, screenW, screenH);
	EmitVertex(vtx1, screenW, screenH);
	EmitVertex(vtx1, screenW, screenH);

	if(m_currentVertex >= 3)
	{
		float nxNDC = nx / screenW * 2.0f;
		float nyNDC = ny / screenH * 2.0f;
		m_mappedVertices[m_currentVertex - 3].position[0] -= nxNDC;
		m_mappedVertices[m_currentVertex - 3].position[1] += nyNDC;
		m_mappedVertices[m_currentVertex - 2].position[0] += nxNDC;
		m_mappedVertices[m_currentVertex - 2].position[1] -= nyNDC;
		m_mappedVertices[m_currentVertex - 1].position[0] -= nxNDC;
		m_mappedVertices[m_currentVertex - 1].position[1] += nyNDC;
	}
}

// ============================================================
// Prim_Triangle
// ============================================================
void CGSH_Metal::Prim_Triangle()
{
	float screenW = m_screenWidth;
	float screenH = m_screenHeight;

	EmitVertex(m_vtxBuffer[2], screenW, screenH);
	EmitVertex(m_vtxBuffer[1], screenW, screenH);
	EmitVertex(m_vtxBuffer[0], screenW, screenH);
}

// ============================================================
// Prim_Sprite
// ============================================================
void CGSH_Metal::Prim_Sprite()
{
	float screenW = m_screenWidth;
	float screenH = m_screenHeight;

	auto& vtx0 = m_vtxBuffer[1];
	auto& vtx1 = m_vtxBuffer[0];

	auto xyz0 = make_convertible<XYZ>(vtx0.position);
	auto xyz1 = make_convertible<XYZ>(vtx1.position);
	float x0 = (xyz0.GetX() - m_primOfsX) / screenW * 2.0f - 1.0f;
	float y0 = -((xyz0.GetY() - m_primOfsY) / screenH * 2.0f - 1.0f);
	float x1 = (xyz1.GetX() - m_primOfsX) / screenW * 2.0f - 1.0f;
	float y1 = -((xyz1.GetY() - m_primOfsY) / screenH * 2.0f - 1.0f);
	float z = (float)xyz1.nZ / 4294967296.0f;

	auto rgbaq = make_convertible<RGBAQ>(vtx1.rgbaq);
	float r = (float)rgbaq.nR / 255.0f;
	float g = (float)rgbaq.nG / 255.0f;
	float b = (float)rgbaq.nB / 255.0f;
	float a = (float)rgbaq.nA / 128.0f;

	float u0 = 0, v0 = 0, u1 = 0, v1 = 0;
	if(m_drawIsTextured)
	{
		if(m_primitiveMode.nUseUV)
		{
			auto uv0r = make_convertible<UV>(vtx0.uv);
			auto uv1r = make_convertible<UV>(vtx1.uv);
			u0 = uv0r.GetU();
			v0 = uv0r.GetV();
			u1 = uv1r.GetU();
			v1 = uv1r.GetV();
		}
		else
		{
			auto st0 = make_convertible<ST>(vtx0.st);
			auto st1 = make_convertible<ST>(vtx1.st);
			float q0 = make_convertible<RGBAQ>(vtx0.rgbaq).nQ;
			float q1 = rgbaq.nQ;
			if(q0 == 0.0f) q0 = 1.0f;
			if(q1 == 0.0f) q1 = 1.0f;
			u0 = st0.nS / q0 * (float)m_texWidth;
			v0 = st0.nT / q0 * (float)m_texHeight;
			u1 = st1.nS / q1 * (float)m_texWidth;
			v1 = st1.nT / q1 * (float)m_texHeight;
		}
	}

	auto emitSpriteVertex = [&](float x, float y, float u, float v) {
		if(m_currentVertex >= MAX_VERTICES) FlushVertices();
		auto& mv = m_mappedVertices[m_currentVertex++];
		mv.position[0] = x;
		mv.position[1] = y;
		mv.position[2] = z;
		mv.position[3] = 1.0f;
		mv.color[0] = r;
		mv.color[1] = g;
		mv.color[2] = b;
		mv.color[3] = a;
		mv.texcoord[0] = u;
		mv.texcoord[1] = v;
		mv.fog = (float)vtx1.fog;
		mv.padding = 0.0f;
	};

	emitSpriteVertex(x0, y0, u0, v0);
	emitSpriteVertex(x1, y0, u1, v0);
	emitSpriteVertex(x0, y1, u0, v1);

	emitSpriteVertex(x1, y0, u1, v0);
	emitSpriteVertex(x1, y1, u1, v1);
	emitSpriteVertex(x0, y1, u0, v1);
}

// ============================================================
// FlushVertices - Submit accumulated vertices using the FRAME-LEVEL encoder
// No new command buffer created here. No waitUntilCompleted.
// ============================================================
void CGSH_Metal::FlushVertices()
{
	if(m_currentVertex == 0) return;

	// Upload any dirty GS memory pages BEFORE drawing
	// This is critical for texture data to be up-to-date, especially
	// since we no longer end the encoder for memory transfers
	if(HasDirtyPages())
	{
		UploadDirtyPages();
	}

	EnsureFrameRenderEncoder();
	if(m_frameRenderEncoder == nil)
	{
		m_currentVertex = 0;
		return;
	}

	// Select pipeline (with state tracking)
	// Use framebuffer fetch pipelines for complex PS2 blend modes on A11+ devices
	id<MTLRenderPipelineState> desiredPipeline;
	if(m_useFramebufferFetch && m_drawPipelineFlatFBFetch && m_drawPipelineTexturedFBFetch)
	{
		desiredPipeline = m_drawIsTextured ? m_drawPipelineTexturedFBFetch : m_drawPipelineFlatFBFetch;
	}
	else
	{
		desiredPipeline = m_drawIsTextured ? m_drawPipelineTextured : m_drawPipelineFlat;
	}
	if(desiredPipeline != m_boundPipelineState)
	{
		[m_frameRenderEncoder setRenderPipelineState:desiredPipeline];
		m_boundPipelineState = desiredPipeline;
	}

	// Select depth state (with state tracking)
	id<MTLDepthStencilState> depthState;
	if(!m_depthEnabled)
	{
		depthState = m_depthWriteEnabled ? m_depthDisabledWrite : m_depthDisabledNoWrite;
	}
	else
	{
		switch(m_depthTestMethod)
		{
		case DEPTH_TEST_NEVER:
			depthState = m_depthStateNever;
			break;
		case DEPTH_TEST_ALWAYS:
			depthState = m_depthStateAlways;
			break;
		case DEPTH_TEST_GEQUAL:
			depthState = m_depthStateGEqual;
			break;
		case DEPTH_TEST_GREATER:
			depthState = m_depthStateGreater;
			break;
		default:
			depthState = m_depthStateAlways;
			break;
		}
	}
	if(depthState != m_boundDepthStencilState)
	{
		[m_frameRenderEncoder setDepthStencilState:depthState];
		m_boundDepthStencilState = depthState;
	}

	// Scissor rect (with state tracking)
	uint32 rtWidth = m_presentColorTexture ? (uint32)[m_presentColorTexture width] : m_presentWidth;
	uint32 rtHeight = m_presentColorTexture ? (uint32)[m_presentColorTexture height] : m_presentHeight;

	MTLScissorRect scissorRect;
	scissorRect.x = m_scissorLeft;
	scissorRect.y = m_scissorTop;
	scissorRect.width = (m_scissorRight > m_scissorLeft) ? (m_scissorRight - m_scissorLeft + 1) : rtWidth;
	scissorRect.height = (m_scissorBottom > m_scissorTop) ? (m_scissorBottom - m_scissorTop + 1) : rtHeight;
	if(scissorRect.x + scissorRect.width > rtWidth)
		scissorRect.width = rtWidth - scissorRect.x;
	if(scissorRect.y + scissorRect.height > rtHeight)
		scissorRect.height = rtHeight - scissorRect.y;
	if(scissorRect.width > 0 && scissorRect.height > 0)
	{
		if(scissorRect.x != m_boundScissorRect.x ||
		   scissorRect.y != m_boundScissorRect.y ||
		   scissorRect.width != m_boundScissorRect.width ||
		   scissorRect.height != m_boundScissorRect.height)
		{
			[m_frameRenderEncoder setScissorRect:scissorRect];
			m_boundScissorRect = scissorRect;
		}
	}

	// Vertex buffer (with state tracking)
	id<MTLBuffer> currentVertexBuffer = m_vertexBuffers[m_currentBufferIndex];
	if(currentVertexBuffer != m_boundVertexBuffer)
	{
		[m_frameRenderEncoder setVertexBuffer:currentVertexBuffer offset:0 atIndex:0];
		m_boundVertexBuffer = currentVertexBuffer;
	}

	// Uniforms - use extended struct for framebuffer fetch
	// Note: Uniforms change frequently, so we always set them (setFragmentBytes is efficient)
	if(m_useFramebufferFetch && m_drawPipelineFlatFBFetch)
	{
		FBFetchUniforms uniforms = {};
		uniforms.texSize = simd_make_float2(m_texWidth, m_texHeight);
		uniforms.screenSize = simd_make_float2(m_screenWidth, m_screenHeight);
		uniforms.alphaFix = (float)m_alphaFix / 128.0f;
		uniforms.fbBasePtr = m_fbBasePtr;
		uniforms.fbWidth = m_fbWidth;
		uniforms.texBasePtr = m_texBasePtr;
		uniforms.texBufWidth = m_texBufWidth;
		uniforms.texPsm = m_texPsm;
		uniforms.clutBasePtr = m_texCLUTPtr;
		uniforms.clutPsm = m_texCLUTPsm;
		uniforms.alphaRef = m_alphaTestRef;
		uniforms.alphaFunc = m_alphaTestEnabled ? m_alphaTestMethod : ALPHA_TEST_ALWAYS;
		uniforms.texFunction = m_texFunction;
		uniforms.alphaTestEnabled = m_alphaTestEnabled ? 1 : 0;
		uniforms.fogColor = simd_make_float3(m_fogR, m_fogG, m_fogB);
		uniforms.fogEnabled = m_primitiveMode.nFog ? 1 : 0;
		uniforms.alphaA = m_alphaA;
		uniforms.alphaB = m_alphaB;
		uniforms.alphaC = m_alphaC;
		uniforms.alphaD = m_alphaD;
		[m_frameRenderEncoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
	}
	else
	{
		DrawUniforms uniforms = {};
		uniforms.texSize = simd_make_float2(m_texWidth, m_texHeight);
		uniforms.screenSize = simd_make_float2(m_screenWidth, m_screenHeight);
		uniforms.alphaFix = (float)m_alphaFix / 128.0f;
		uniforms.fbBasePtr = m_fbBasePtr;
		uniforms.fbWidth = m_fbWidth;
		uniforms.texBasePtr = m_texBasePtr;
		uniforms.texBufWidth = m_texBufWidth;
		uniforms.texPsm = m_texPsm;
		uniforms.clutBasePtr = m_texCLUTPtr;
		uniforms.clutPsm = m_texCLUTPsm;
		uniforms.alphaRef = m_alphaTestRef;
		uniforms.alphaFunc = m_alphaTestEnabled ? m_alphaTestMethod : ALPHA_TEST_ALWAYS;
		uniforms.texFunction = m_texFunction;
		uniforms.alphaTestEnabled = m_alphaTestEnabled ? 1 : 0;
		uniforms.fogColor = simd_make_float3(m_fogR, m_fogG, m_fogB);
		uniforms.fogEnabled = m_primitiveMode.nFog ? 1 : 0;
		[m_frameRenderEncoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
	}

	// Texture buffers (with state tracking - these don't change often)
	if(m_drawIsTextured && !m_texturedStateSet)
	{
		[m_frameRenderEncoder setFragmentBuffer:m_gsMemoryBuffer offset:0 atIndex:1];
		[m_frameRenderEncoder setFragmentBuffer:m_clutBuffer offset:0 atIndex:2];
		[m_frameRenderEncoder setFragmentBuffer:m_swizzleTablePSMCT32 offset:0 atIndex:3];
		[m_frameRenderEncoder setFragmentBuffer:m_swizzleTablePSMCT16 offset:0 atIndex:4];
		[m_frameRenderEncoder setFragmentBuffer:m_swizzleTablePSMT8 offset:0 atIndex:5];
		m_texturedStateSet = true;
	}

	[m_frameRenderEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:m_currentVertex];

	m_currentVertex = 0;
}

void CGSH_Metal::UploadGSMemory()
{
	if(!m_memoryCache || !m_gsMemoryBuffer) return;
	memcpy([m_gsMemoryBuffer contents], m_memoryCache, GS_RAM_SIZE);
}

// ============================================================
// Dirty page tracking for efficient GS memory uploads
// ============================================================
void CGSH_Metal::MarkPagesDirty(uint32 startAddr, uint32 size)
{
	if(size == 0) return;

	uint32 startPage = (startAddr & (GS_RAM_SIZE - 1)) / GS_PAGE_SIZE;
	uint32 endAddr = startAddr + size;
	uint32 endPage = ((endAddr - 1) & (GS_RAM_SIZE - 1)) / GS_PAGE_SIZE;

	// Handle wrap-around in GS memory
	if(endPage < startPage)
	{
		// Mark from startPage to end
		for(uint32 p = startPage; p < GS_PAGE_COUNT; p++)
		{
			m_dirtyPageBitmap[p / 64] |= (1ULL << (p % 64));
		}
		// Mark from beginning to endPage
		for(uint32 p = 0; p <= endPage; p++)
		{
			m_dirtyPageBitmap[p / 64] |= (1ULL << (p % 64));
		}
	}
	else
	{
		for(uint32 p = startPage; p <= endPage; p++)
		{
			m_dirtyPageBitmap[p / 64] |= (1ULL << (p % 64));
		}
	}
}

void CGSH_Metal::MarkAllPagesDirty()
{
	for(int i = 0; i < 8; i++)
	{
		m_dirtyPageBitmap[i] = 0xFFFFFFFFFFFFFFFF;
	}
}

void CGSH_Metal::ClearDirtyPages()
{
	for(int i = 0; i < 8; i++)
	{
		m_dirtyPageBitmap[i] = 0;
	}
}

bool CGSH_Metal::HasDirtyPages() const
{
	for(int i = 0; i < 8; i++)
	{
		if(m_dirtyPageBitmap[i] != 0) return true;
	}
	return false;
}

void CGSH_Metal::UploadDirtyPages()
{
	if(!m_memoryCache || !m_gsMemoryBuffer) return;
	if(!HasDirtyPages()) return;

	uint8* dst = static_cast<uint8*>([m_gsMemoryBuffer contents]);
	uint32 uploadedBytes = 0;

	// Coalesce adjacent dirty pages into single memcpy calls
	uint32 runStart = GS_PAGE_COUNT;
	for(uint32 p = 0; p < GS_PAGE_COUNT; p++)
	{
		bool isDirty = (m_dirtyPageBitmap[p / 64] & (1ULL << (p % 64))) != 0;

		if(isDirty)
		{
			if(runStart == GS_PAGE_COUNT)
			{
				runStart = p;
			}
		}
		else
		{
			if(runStart != GS_PAGE_COUNT)
			{
				// End of a dirty run, copy it
				uint32 startOffset = runStart * GS_PAGE_SIZE;
				uint32 runSize = (p - runStart) * GS_PAGE_SIZE;
				memcpy(dst + startOffset, m_memoryCache + startOffset, runSize);
				uploadedBytes += runSize;
				runStart = GS_PAGE_COUNT;
			}
		}
	}

	// Handle final run if it extends to the end
	if(runStart != GS_PAGE_COUNT)
	{
		uint32 startOffset = runStart * GS_PAGE_SIZE;
		uint32 runSize = (GS_PAGE_COUNT - runStart) * GS_PAGE_SIZE;
		memcpy(dst + startOffset, m_memoryCache + startOffset, runSize);
		uploadedBytes += runSize;
	}

	ClearDirtyPages();

	// Log upload efficiency (commented out for release)
	// NSLog(@"[GSH_Metal] Uploaded %u bytes of %u total (%.1f%%)",
	//       uploadedBytes, GS_RAM_SIZE, 100.0f * uploadedBytes / GS_RAM_SIZE);
}

// ============================================================
// SyncCLUT
// ============================================================
void CGSH_Metal::SyncCLUT(const TEX0& tex0)
{
	if(!m_clutBuffer || !m_memoryCache) return;

	bool isIDTEX4 = CGsPixelFormats::IsPsmIDTEX4(tex0.nPsm);
	uint32 clutEntryCount = isIDTEX4 ? 16 : 256;

	uint32 clutPtr = tex0.GetCLUTPtr();
	uint32 csa = tex0.nCSA;
	uint32 cpsm = tex0.nCPSM;

	uint32_t* clutDst = static_cast<uint32_t*>([m_clutBuffer contents]);

	if(cpsm == PSMCT32)
	{
		CGsPixelFormats::CPixelIndexorPSMCT32 indexor(m_memoryCache, clutPtr, 1);
		for(uint32 i = 0; i < clutEntryCount; i++)
		{
			uint32 color = indexor.GetPixel(i + csa * 16, 0);
			clutDst[i] = color;
		}
	}
	else if(cpsm == PSMCT16 || cpsm == PSMCT16S)
	{
		CGsPixelFormats::CPixelIndexorPSMCT16 indexor(m_memoryCache, clutPtr, 1);
		for(uint32 i = 0; i < clutEntryCount; i++)
		{
			uint16 color16 = indexor.GetPixel(i + csa * 16, 0);
			uint32 r = ((color16 >> 0) & 0x1F) << 3;
			uint32 g = ((color16 >> 5) & 0x1F) << 3;
			uint32 b = ((color16 >> 10) & 0x1F) << 3;
			uint32 a = ((color16 >> 15) & 0x01) ? 0x80 : 0;
			clutDst[i] = r | (g << 8) | (b << 16) | (a << 24);
		}
	}
}

// ============================================================
// FlipImpl - Frame end: flush, present, commit
// ============================================================
void CGSH_Metal::FlipImpl(const DISPLAY_INFO& dispInfo)
{
	FlushVertices();

	if(dispInfo.width > 0 && dispInfo.height > 0)
	{
		m_screenWidth = (float)dispInfo.width;
		m_screenHeight = (float)dispInfo.height;
	}

	// End the draw render encoder before present
	EndFrameRenderEncoder();

	DoPresent(dispInfo);

	// Reset frame state for next frame
	m_frameClearedThisFrame = false;
	m_frameCommandBuffer = nil;

	// Cycle to next triple-buffered resources
	m_currentBufferIndex = (m_currentBufferIndex + 1) % MAX_INFLIGHT_FRAMES;
	m_mappedVertices = static_cast<MetalVertex*>([m_vertexBuffers[m_currentBufferIndex] contents]);

	CGSHandler::FlipImpl(dispInfo);
}

// ============================================================
// DoPresent - Blit m_presentColorTexture to the CAMetalLayer drawable
// This is the ONLY place where a command buffer is committed per frame.
// ============================================================
void CGSH_Metal::DoPresent(const DISPLAY_INFO& dispInfo)
{
	if(!m_metalLayer) return;

	@autoreleasepool
	{
		// Wait for a free inflight frame slot
		dispatch_semaphore_wait(m_inflightSemaphore, DISPATCH_TIME_FOREVER);

		m_currentDrawable = [m_metalLayer nextDrawable];
		if(!m_currentDrawable)
		{
			dispatch_semaphore_signal(m_inflightSemaphore);
			return;
		}

		EnsureFrameCommandBuffer();

		// Add completion handler to signal the semaphore
		__block dispatch_semaphore_t semaphore = m_inflightSemaphore;
		[m_frameCommandBuffer addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull) {
		  dispatch_semaphore_signal(semaphore);
		}];

		MTLRenderPassDescriptor* renderPass = [MTLRenderPassDescriptor renderPassDescriptor];
		renderPass.colorAttachments[0].texture = [m_currentDrawable texture];
		renderPass.colorAttachments[0].loadAction = MTLLoadActionClear;
		renderPass.colorAttachments[0].storeAction = MTLStoreActionStore;
		renderPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);

		id<MTLRenderCommandEncoder> encoder = [m_frameCommandBuffer renderCommandEncoderWithDescriptor:renderPass];

		if(m_presentColorTexture != nil)
		{
			// Blit the rendered framebuffer texture to the drawable
			[encoder setRenderPipelineState:m_presentPipeline];
			[encoder setFragmentTexture:m_presentColorTexture atIndex:0];
			[encoder setFragmentSamplerState:m_samplerBilinear atIndex:0];
			[encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
		}

		[encoder endEncoding];
		[m_frameCommandBuffer presentDrawable:m_currentDrawable];
		[m_frameCommandBuffer commit];

		m_currentDrawable = nil;
	}
}

// ============================================================
// Transfer operations
// ============================================================
void CGSH_Metal::ProcessHostToLocalTransfer()
{
	// DON'T end the render encoder here - it causes massive performance loss
	// (60 encoder recreations per frame). Instead, just mark pages dirty and
	// let UploadDirtyPages() handle the sync before the next draw.
	FlushVertices();

	// Get transfer parameters to determine which pages are affected
	auto bltBuf = make_convertible<BITBLTBUF>(m_nReg[GS_REG_BITBLTBUF]);
	auto trxReg = make_convertible<TRXREG>(m_nReg[GS_REG_TRXREG]);

	if(m_pRAM && m_memoryCache)
	{
		memcpy(m_memoryCache, m_pRAM, GS_RAM_SIZE);
	}

	// Mark destination region as dirty
	// Estimate affected size: width * height * bytes per pixel (4 for PSMCT32)
	uint32 dstPtr = bltBuf.GetDstPtr();
	uint32 transferSize = trxReg.nRRW * trxReg.nRRH * 4;
	if(transferSize > 0)
	{
		MarkPagesDirty(dstPtr, transferSize);
	}
	else
	{
		// Fallback: mark all pages dirty if we can't determine the region
		MarkAllPagesDirty();
	}
}

void CGSH_Metal::ProcessLocalToHostTransfer()
{
	if(m_pRAM && m_memoryCache)
	{
		memcpy(m_pRAM, m_memoryCache, GS_RAM_SIZE);
	}
}

void CGSH_Metal::ProcessLocalToLocalTransfer()
{
	// DON'T end the render encoder - just flush vertices
	FlushVertices();

	auto bltBuf = make_convertible<BITBLTBUF>(m_nReg[GS_REG_BITBLTBUF]);
	auto trxPos = make_convertible<TRXPOS>(m_nReg[GS_REG_TRXPOS]);
	auto trxReg = make_convertible<TRXREG>(m_nReg[GS_REG_TRXREG]);

	// Skip if no work to do
	if(trxReg.nRRW == 0 || trxReg.nRRH == 0) return;

	// Try GPU-accelerated transfer first
	if(m_localTransferPipeline != nil && m_gsMemoryBuffer != nil)
	{
		// End render encoder to switch to compute
		EndFrameRenderEncoder();

		// Ensure we have a command buffer
		EnsureFrameCommandBuffer();

		// Sync CPU memory to GPU buffer before compute
		if(m_pRAM && m_memoryCache)
		{
			memcpy(m_memoryCache, m_pRAM, GS_RAM_SIZE);
		}
		UploadDirtyPages();

		// Create compute encoder
		id<MTLComputeCommandEncoder> computeEncoder = [m_frameCommandBuffer computeCommandEncoder];
		if(computeEncoder)
		{
			computeEncoder.label = @"Local Transfer";

			// Set up transfer parameters
			TransferParams params;
			params.srcBufPtr = bltBuf.GetSrcPtr();
			params.srcBufWidth = bltBuf.GetSrcWidth();
			params.dstBufPtr = bltBuf.GetDstPtr();
			params.dstBufWidth = bltBuf.GetDstWidth();
			params.srcX = trxPos.nSSAX;
			params.srcY = trxPos.nSSAY;
			params.dstX = trxPos.nDSAX;
			params.dstY = trxPos.nDSAY;
			params.width = trxReg.nRRW;
			params.height = trxReg.nRRH;

			[computeEncoder setComputePipelineState:m_localTransferPipeline];
			[computeEncoder setBuffer:m_gsMemoryBuffer offset:0 atIndex:0];
			[computeEncoder setBuffer:m_swizzleTablePSMCT32 offset:0 atIndex:1];
			[computeEncoder setBytes:&params length:sizeof(params) atIndex:2];

			// Calculate thread groups
			MTLSize threadsPerGroup = MTLSizeMake(16, 16, 1);
			MTLSize numGroups = MTLSizeMake(
			    (params.width + 15) / 16,
			    (params.height + 15) / 16,
			    1);

			[computeEncoder dispatchThreadgroups:numGroups threadsPerThreadgroup:threadsPerGroup];
			[computeEncoder endEncoding];

			// Read back modified data to CPU memory
			// Note: This sync is necessary for CPU-side operations that may follow
			[m_frameCommandBuffer commit];
			[m_frameCommandBuffer waitUntilCompleted];
			m_frameCommandBuffer = nil;

			// Sync GPU buffer back to CPU
			if(m_pRAM)
			{
				void* bufferContents = [m_gsMemoryBuffer contents];
				memcpy(m_pRAM, bufferContents, GS_RAM_SIZE);
				if(m_memoryCache)
				{
					memcpy(m_memoryCache, m_pRAM, GS_RAM_SIZE);
				}
			}

			// Mark destination region as dirty for next render
			uint32 dstPtr = bltBuf.GetDstPtr();
			uint32 transferSize = trxReg.nRRW * trxReg.nRRH * 4;
			MarkPagesDirty(dstPtr, transferSize);
			return;
		}
	}

	// Fallback to CPU implementation if GPU transfer not available
	if(m_pRAM && m_memoryCache)
	{
		memcpy(m_pRAM, m_memoryCache, GS_RAM_SIZE);
	}

	for(uint32 y = 0; y < trxReg.nRRH; y++)
	{
		for(uint32 x = 0; x < trxReg.nRRW; x++)
		{
			uint32 srcX = trxPos.nSSAX + x;
			uint32 srcY = trxPos.nSSAY + y;
			uint32 dstX = trxPos.nDSAX + x;
			uint32 dstY = trxPos.nDSAY + y;

			CGsPixelFormats::CPixelIndexorPSMCT32 srcIdx(m_pRAM, bltBuf.GetSrcPtr(), bltBuf.GetSrcWidth());
			CGsPixelFormats::CPixelIndexorPSMCT32 dstIdx(m_pRAM, bltBuf.GetDstPtr(), bltBuf.GetDstWidth());
			uint32 pixel = srcIdx.GetPixel(srcX, srcY);
			dstIdx.SetPixel(dstX, dstY, pixel);
		}
	}

	if(m_pRAM && m_memoryCache)
	{
		memcpy(m_memoryCache, m_pRAM, GS_RAM_SIZE);
	}

	// Mark destination region as dirty
	uint32 dstPtr = bltBuf.GetDstPtr();
	uint32 transferSize = trxReg.nRRW * trxReg.nRRH * 4;
	MarkPagesDirty(dstPtr, transferSize);
}

void CGSH_Metal::ProcessClutTransfer(uint32 csa, uint32 csm)
{
}

// ============================================================
// CLUT cache helpers
// ============================================================
CGSH_Metal::CLUTKEY CGSH_Metal::MakeCachedClutKey(const TEX0& tex0) const
{
	CLUTKEY key;
	memset(&key, 0, sizeof(key));
	key.idx4 = CGsPixelFormats::IsPsmIDTEX4(tex0.nPsm) ? 1 : 0;
	key.cbp = tex0.nCBP;
	key.cpsm = tex0.nCPSM;
	key.csm = tex0.nCSM;
	key.csa = tex0.nCSA;
	return key;
}

int32 CGSH_Metal::FindCachedClut(const CLUTKEY& key) const
{
	for(uint32 i = 0; i < CLUT_CACHE_SIZE; i++)
	{
		if(memcmp(&m_clutStates[i], &key, sizeof(CLUTKEY)) == 0)
		{
			return static_cast<int32>(i);
		}
	}
	return -1;
}

// ============================================================
// PrecompileShaders - Warm up GPU shader cache before gameplay
// This reduces stuttering by ensuring all shader variants are
// compiled and cached by the GPU driver before actual use.
// ============================================================
void CGSH_Metal::PrecompileShaders()
{
	@autoreleasepool
	{
		NSLog(@"[GSH_Metal] Pre-compiling shader variants...");

		// Create a temporary render target for pre-compilation
		MTLTextureDescriptor* texDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
		                                                                                   width:64
		                                                                                  height:64
		                                                                               mipmapped:NO];
		texDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
		texDesc.storageMode = MTLStorageModePrivate;
		id<MTLTexture> tempColorTex = [m_device newTextureWithDescriptor:texDesc];

		MTLTextureDescriptor* depthDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
		                                                                                     width:64
		                                                                                    height:64
		                                                                                 mipmapped:NO];
		depthDesc.usage = MTLTextureUsageRenderTarget;
		depthDesc.storageMode = MTLStorageModePrivate;
		id<MTLTexture> tempDepthTex = [m_device newTextureWithDescriptor:depthDesc];

		// Create command buffer for pre-compilation
		id<MTLCommandBuffer> cmdBuffer = [m_commandQueue commandBuffer];
		cmdBuffer.label = @"GSH_Metal Shader Precompile";

		MTLRenderPassDescriptor* renderPass = [MTLRenderPassDescriptor renderPassDescriptor];
		renderPass.colorAttachments[0].texture = tempColorTex;
		renderPass.colorAttachments[0].loadAction = MTLLoadActionClear;
		renderPass.colorAttachments[0].storeAction = MTLStoreActionStore;
		renderPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
		renderPass.depthAttachment.texture = tempDepthTex;
		renderPass.depthAttachment.loadAction = MTLLoadActionClear;
		renderPass.depthAttachment.storeAction = MTLStoreActionStore;
		renderPass.depthAttachment.clearDepth = 0.0;

		id<MTLRenderCommandEncoder> encoder = [cmdBuffer renderCommandEncoderWithDescriptor:renderPass];

		// Warm up each pipeline state by binding it
		// The GPU driver will compile/cache the shader when first bound
		NSArray* pipelines = @[];
		if(m_drawPipelineFlat) pipelines = [pipelines arrayByAddingObject:m_drawPipelineFlat];
		if(m_drawPipelineTextured) pipelines = [pipelines arrayByAddingObject:m_drawPipelineTextured];
		if(m_drawPipelineFlatFBFetch) pipelines = [pipelines arrayByAddingObject:m_drawPipelineFlatFBFetch];
		if(m_drawPipelineTexturedFBFetch) pipelines = [pipelines arrayByAddingObject:m_drawPipelineTexturedFBFetch];
		if(m_presentPipeline) pipelines = [pipelines arrayByAddingObject:m_presentPipeline];

		// Warm up each depth state
		NSArray* depthStates = @[];
		if(m_depthStateNever) depthStates = [depthStates arrayByAddingObject:m_depthStateNever];
		if(m_depthStateAlways) depthStates = [depthStates arrayByAddingObject:m_depthStateAlways];
		if(m_depthStateGEqual) depthStates = [depthStates arrayByAddingObject:m_depthStateGEqual];
		if(m_depthStateGreater) depthStates = [depthStates arrayByAddingObject:m_depthStateGreater];
		if(m_depthDisabledWrite) depthStates = [depthStates arrayByAddingObject:m_depthDisabledWrite];
		if(m_depthDisabledNoWrite) depthStates = [depthStates arrayByAddingObject:m_depthDisabledNoWrite];

		// Bind each pipeline and depth state combination to warm up the cache
		for(id<MTLRenderPipelineState> pipeline in pipelines)
		{
			[encoder setRenderPipelineState:pipeline];
			for(id<MTLDepthStencilState> depthState in depthStates)
			{
				[encoder setDepthStencilState:depthState];
			}
		}

		[encoder endEncoding];

		// Commit and wait for completion to ensure shaders are fully compiled
		[cmdBuffer commit];
		[cmdBuffer waitUntilCompleted];

		NSLog(@"[GSH_Metal] Pre-compiled %lu pipeline states with %lu depth states",
		      (unsigned long)[pipelines count], (unsigned long)[depthStates count]);
	}
}
