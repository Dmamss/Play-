#import "GSH_Metal.h"
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <simd/simd.h>
#include "../GsPixelFormats.h"
#include <cstring>
#include <algorithm>

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
    , m_presentPipeline(nil)
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
    , m_vertexBuffer(nil)
    , m_drawUniformBuffer(nil)
    , m_currentDrawable(nil)
    , m_metalLayer(nil)
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
	CreateDevice();
	CreateBuffers();
	CreateSwizzleTables();
	CreatePipelineStates();
	CreateDepthStencilStates();
	CreateSamplerStates();

	m_memoryCache = new uint8[GS_RAM_SIZE];
	memset(m_memoryCache, 0, GS_RAM_SIZE);

	CGSHandler::InitializeImpl();
}

void CGSH_Metal::ReleaseImpl()
{
	FlushVertices();

	m_drawPipelineFlat = nil;
	m_drawPipelineTextured = nil;
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
	m_vertexBuffer = nil;
	m_drawUniformBuffer = nil;
	m_currentDrawable = nil;
	m_library = nil;
	m_commandQueue = nil;
	m_device = nil;

	delete[] m_memoryCache;
	m_memoryCache = nullptr;

	CGSHandler::ReleaseImpl();
}

void CGSH_Metal::ResetImpl()
{
	m_vtxCount = 0;
	m_pendingPrim = false;
	m_currentVertex = 0;
	m_nextClutCacheIndex = 0;
	m_xferBuffer.clear();
	m_drawIsTextured = false;
	m_primitiveType = PRIM_INVALID;

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
}

void CGSH_Metal::CreateDevice()
{
	m_device = MTLCreateSystemDefaultDevice();
	assert(m_device != nil);

	m_commandQueue = [m_device newCommandQueue];
	assert(m_commandQueue != nil);

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

	// Vertex buffer
	m_vertexBuffer = [m_device newBufferWithLength:VERTEX_BUFFER_SIZE
	                                       options:MTLResourceStorageModeShared];
	m_mappedVertices = static_cast<MetalVertex*>([m_vertexBuffer contents]);

	// Uniform buffer for draw calls
	m_drawUniformBuffer = [m_device newBufferWithLength:sizeof(DrawUniforms)
	                                            options:MTLResourceStorageModeShared];
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

	// Load the default Metal library (compiled .metal shaders)
	m_library = [m_device newDefaultLibrary];
	if(!m_library)
	{
		// Try loading from a metallib file
		NSString* libPath = [[NSBundle mainBundle] pathForResource:@"GSH_MetalShaders" ofType:@"metallib"];
		if(libPath)
		{
			NSURL* libURL = [NSURL fileURLWithPath:libPath];
			m_library = [m_device newLibraryWithURL:libURL error:&error];
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
// Swizzle helper: PSMCT32 address computation
// Given a pixel coordinate (x, y), buffer pointer and buffer width,
// compute the byte offset in GS RAM using the page offset table.
// ============================================================
uint computeAddressPSMCT32(int x, int y, uint bufPtr, uint bufWidth,
                           constant uint* swizzleTable) {
    // PSMCT32: page = 64x32, 8192 bytes per page
    const uint pageWidth = 64;
    const uint pageHeight = 32;
    const uint pageSize = 8192;

    uint pagesPerRow = bufWidth / pageWidth;
    uint pageX = x / pageWidth;
    uint pageY = y / pageHeight;
    uint page = pageY * pagesPerRow + pageX;

    uint localX = x % pageWidth;
    uint localY = y % pageHeight;

    uint pageOffset = swizzleTable[localY * pageWidth + localX];
    uint address = bufPtr + page * pageSize + pageOffset;
    return address & 0x003FFFFF; // wrap to 4MB
}

// ============================================================
// Swizzle helper: PSMCT16 address computation
// ============================================================
uint computeAddressPSMCT16(int x, int y, uint bufPtr, uint bufWidth,
                            constant uint* swizzleTable) {
    const uint pageWidth = 64;
    const uint pageHeight = 64;
    const uint pageSize = 8192;

    uint pagesPerRow = bufWidth / pageWidth;
    uint pageX = x / pageWidth;
    uint pageY = y / pageHeight;
    uint page = pageY * pagesPerRow + pageX;

    uint localX = x % pageWidth;
    uint localY = y % pageHeight;

    uint pageOffset = swizzleTable[localY * pageWidth + localX];
    uint address = bufPtr + page * pageSize + pageOffset;
    return address & 0x003FFFFF;
}

// ============================================================
// Swizzle helper: PSMT8 address computation
// ============================================================
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

// ============================================================
// Read a 32-bit pixel from GS memory (as uint words)
// ============================================================
uint readPixelPSMCT32(int x, int y, uint bufPtr, uint bufWidth,
                       constant uint* gsMemory, constant uint* swizzleTable) {
    uint addr = computeAddressPSMCT32(x, y, bufPtr, bufWidth, swizzleTable);
    uint wordAddr = addr / 4;
    if(wordAddr >= 1048576) return 0;
    return gsMemory[wordAddr];
}

// ============================================================
// Read a 16-bit pixel from GS memory
// ============================================================
uint readPixelPSMCT16(int x, int y, uint bufPtr, uint bufWidth,
                       constant uchar* gsMemoryBytes, constant uint* swizzleTable) {
    uint addr = computeAddressPSMCT16(x, y, bufPtr, bufWidth, swizzleTable);
    if(addr + 1 >= 4194304) return 0;
    return uint(gsMemoryBytes[addr]) | (uint(gsMemoryBytes[addr + 1]) << 8);
}

// ============================================================
// Read an 8-bit index from GS memory (PSMT8)
// ============================================================
uint readPixelPSMT8(int x, int y, uint bufPtr, uint bufWidth,
                     constant uchar* gsMemoryBytes, constant uint* swizzleTable) {
    uint addr = computeAddressPSMT8(x, y, bufPtr, bufWidth, swizzleTable);
    if(addr >= 4194304) return 0;
    return uint(gsMemoryBytes[addr]);
}

// ============================================================
// Convert a packed RGBA32 word to float4
// ============================================================
float4 unpackColor32(uint pixel) {
    float4 c;
    c.r = float((pixel >>  0) & 0xFF) / 255.0;
    c.g = float((pixel >>  8) & 0xFF) / 255.0;
    c.b = float((pixel >> 16) & 0xFF) / 255.0;
    c.a = float((pixel >> 24) & 0xFF) / 128.0; // PS2 alpha is 0-128
    return c;
}

// ============================================================
// Convert a 16-bit color to float4
// ============================================================
float4 unpackColor16(uint pixel) {
    float4 c;
    c.r = float(((pixel >>  0) & 0x1F)) / 31.0;
    c.g = float(((pixel >>  5) & 0x1F)) / 31.0;
    c.b = float(((pixel >> 10) & 0x1F)) / 31.0;
    c.a = float((pixel >> 15) & 1);
    return c;
}

// ============================================================
// Alpha test
// ============================================================
bool alphaTest(float alphaValue, uint alphaFunc, uint alphaRef) {
    uint aRef = alphaRef;
    uint aVal = uint(clamp(alphaValue * 255.0, 0.0, 255.0));

    switch(alphaFunc) {
        case 0: return false;               // NEVER
        case 1: return true;                // ALWAYS
        case 2: return aVal < aRef;         // LESS
        case 3: return aVal <= aRef;        // LEQUAL
        case 4: return aVal == aRef;        // EQUAL
        case 5: return aVal >= aRef;        // GEQUAL
        case 6: return aVal > aRef;         // GREATER
        case 7: return aVal != aRef;        // NOTEQUAL
        default: return true;
    }
}

// ============================================================
// Vertex shader for drawing primitives
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
// Fragment shader: flat (untextured) drawing
// ============================================================
fragment float4 fs_draw_flat(VertexOut in [[stage_in]],
                              constant DrawUniforms& uniforms [[buffer(0)]]) {
    float4 color = in.color;

    // Alpha test
    if(uniforms.alphaTestEnabled != 0) {
        if(!alphaTest(color.a, uniforms.alphaFunc, uniforms.alphaRef)) {
            discard_fragment();
        }
    }

    // Fog
    if(uniforms.fogEnabled != 0) {
        float fogFactor = in.fog / 255.0;
        color.rgb = mix(uniforms.fogColor, color.rgb, fogFactor);
    }

    return color;
}

// ============================================================
// Fragment shader: textured drawing
// Supports PSMCT32, PSMCT16, PSMT8 (with CLUT), PSMT4 (with CLUT)
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
        // PSMCT32 / PSMCT24
        uint pixel = readPixelPSMCT32(texCoord.x, texCoord.y,
                                       uniforms.texBasePtr, uniforms.texBufWidth,
                                       gsMemory, swizzleTableCT32);
        texColor = unpackColor32(pixel);
        if(psm == 0x01) texColor.a = 1.0; // PSMCT24: no alpha
    }
    else if(psm == 0x02 || psm == 0x0A) {
        // PSMCT16 / PSMCT16S
        uint pixel = readPixelPSMCT16(texCoord.x, texCoord.y,
                                       uniforms.texBasePtr, uniforms.texBufWidth,
                                       gsMemBytes, swizzleTableCT16);
        texColor = unpackColor16(pixel);
    }
    else if(psm == 0x13) {
        // PSMT8 - indexed, use CLUT
        uint index = readPixelPSMT8(texCoord.x, texCoord.y,
                                     uniforms.texBasePtr, uniforms.texBufWidth,
                                     gsMemBytes, swizzleTableT8);
        uint clutEntry = clutData[index & 0xFF];
        texColor = unpackColor32(clutEntry);
    }
    else if(psm == 0x14) {
        // PSMT4 - 4-bit indexed, use CLUT
        // Read as 8-bit and extract nibble
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
    }
    else if(psm == 0x1B) {
        // PSMT8H - 8-bit index stored in high byte of 32-bit word
        uint pixel = readPixelPSMCT32(texCoord.x, texCoord.y,
                                       uniforms.texBasePtr, uniforms.texBufWidth,
                                       gsMemory, swizzleTableCT32);
        uint index = (pixel >> 24) & 0xFF;
        uint clutEntry = clutData[index];
        texColor = unpackColor32(clutEntry);
    }
    else if(psm == 0x24) {
        // PSMT4HL - 4-bit index in bits 24-27
        uint pixel = readPixelPSMCT32(texCoord.x, texCoord.y,
                                       uniforms.texBasePtr, uniforms.texBufWidth,
                                       gsMemory, swizzleTableCT32);
        uint index = (pixel >> 24) & 0x0F;
        uint clutEntry = clutData[index];
        texColor = unpackColor32(clutEntry);
    }
    else if(psm == 0x2C) {
        // PSMT4HH - 4-bit index in bits 28-31
        uint pixel = readPixelPSMCT32(texCoord.x, texCoord.y,
                                       uniforms.texBasePtr, uniforms.texBufWidth,
                                       gsMemory, swizzleTableCT32);
        uint index = (pixel >> 28) & 0x0F;
        uint clutEntry = clutData[index];
        texColor = unpackColor32(clutEntry);
    }
    else {
        // Fallback: direct linear read as PSMCT32
        uint addr = (uniforms.texBasePtr + (texCoord.y * uniforms.texBufWidth + texCoord.x) * 4) / 4;
        if(addr < 1048576) {
            texColor = unpackColor32(gsMemory[addr]);
        } else {
            texColor = float4(1, 0, 1, 1); // magenta = unhandled format
        }
    }

    // Texture function application
    float4 color;
    uint texFunc = uniforms.texFunction;
    if(texFunc == 0) {
        // MODULATE
        color = texColor * in.color;
    } else if(texFunc == 1) {
        // DECAL
        color = texColor;
    } else if(texFunc == 2) {
        // HIGHLIGHT
        color.rgb = texColor.rgb * in.color.rgb + in.color.aaa;
        color.a = texColor.a + in.color.a;
    } else if(texFunc == 3) {
        // HIGHLIGHT2
        color.rgb = texColor.rgb * in.color.rgb + in.color.aaa;
        color.a = texColor.a;
    } else {
        color = texColor * in.color;
    }

    // Alpha test
    if(uniforms.alphaTestEnabled != 0) {
        if(!alphaTest(color.a, uniforms.alphaFunc, uniforms.alphaRef)) {
            discard_fragment();
        }
    }

    // Fog
    if(uniforms.fogEnabled != 0) {
        float fogFactor = in.fog / 255.0;
        color.rgb = mix(uniforms.fogColor, color.rgb, fogFactor);
    }

    return color;
}

// ============================================================
// Present pass
// ============================================================
struct PresentUniforms {
    float2 srcSize;
    float2 dstSize;
    uint fbPtr;
    uint fbWidth;
    uint fbPsm;
};

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
                           constant PresentUniforms& uniforms [[buffer(0)]],
                           constant uint* gsMemory [[buffer(1)]],
                           constant uint* swizzleTableCT32 [[buffer(2)]],
                           constant uint* swizzleTableCT16 [[buffer(3)]]) {
    int2 coord = int2(in.texcoord * uniforms.srcSize);
    coord.x = clamp(coord.x, 0, int(uniforms.srcSize.x) - 1);
    coord.y = clamp(coord.y, 0, int(uniforms.srcSize.y) - 1);

    float4 color;

    if(uniforms.fbPsm == 0 || uniforms.fbPsm == 1) {
        // PSMCT32 / PSMCT24 with proper swizzle
        uint pixel = readPixelPSMCT32(coord.x, coord.y, uniforms.fbPtr,
                                       uniforms.fbWidth, gsMemory, swizzleTableCT32);
        color.r = float((pixel >>  0) & 0xFF) / 255.0;
        color.g = float((pixel >>  8) & 0xFF) / 255.0;
        color.b = float((pixel >> 16) & 0xFF) / 255.0;
        color.a = 1.0;
    } else if(uniforms.fbPsm == 2 || uniforms.fbPsm == 0x0A) {
        // PSMCT16 / PSMCT16S with proper swizzle
        constant uchar* gsMemBytes = reinterpret_cast<constant uchar*>(gsMemory);
        uint pixel = readPixelPSMCT16(coord.x, coord.y, uniforms.fbPtr,
                                       uniforms.fbWidth, gsMemBytes, swizzleTableCT16);
        color.r = float(((pixel >>  0) & 0x1F)) / 31.0;
        color.g = float(((pixel >>  5) & 0x1F)) / 31.0;
        color.b = float(((pixel >> 10) & 0x1F)) / 31.0;
        color.a = 1.0;
    } else {
        // Fallback: treat as PSMCT32 with swizzle
        uint pixel = readPixelPSMCT32(coord.x, coord.y, uniforms.fbPtr,
                                       uniforms.fbWidth, gsMemory, swizzleTableCT32);
        color.r = float((pixel >>  0) & 0xFF) / 255.0;
        color.g = float((pixel >>  8) & 0xFF) / 255.0;
        color.b = float((pixel >> 16) & 0xFF) / 255.0;
        color.a = 1.0;
    }
    return color;
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

	// Flat draw pipeline (alpha blending enabled by default)
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

	// Present pipeline
	{
		MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
		desc.label = @"GSH_Metal Present";
		desc.vertexFunction = [m_library newFunctionWithName:@"vs_present"];
		desc.fragmentFunction = [m_library newFunctionWithName:@"fs_present"];
		desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

		m_presentPipeline = [m_device newRenderPipelineStateWithDescriptor:desc error:&error];
		if(error) NSLog(@"[GSH_Metal] Present pipeline error: %@", error);
	}
}

void CGSH_Metal::CreateDepthStencilStates()
{
	// NEVER - depth test never passes
	{
		MTLDepthStencilDescriptor* desc = [[MTLDepthStencilDescriptor alloc] init];
		desc.depthCompareFunction = MTLCompareFunctionNever;
		desc.depthWriteEnabled = NO;
		m_depthStateNever = [m_device newDepthStencilStateWithDescriptor:desc];
	}
	// ALWAYS - depth test always passes, writes depth
	{
		MTLDepthStencilDescriptor* desc = [[MTLDepthStencilDescriptor alloc] init];
		desc.depthCompareFunction = MTLCompareFunctionAlways;
		desc.depthWriteEnabled = YES;
		m_depthStateAlways = [m_device newDepthStencilStateWithDescriptor:desc];
	}
	// GEQUAL
	{
		MTLDepthStencilDescriptor* desc = [[MTLDepthStencilDescriptor alloc] init];
		desc.depthCompareFunction = MTLCompareFunctionGreaterEqual;
		desc.depthWriteEnabled = YES;
		m_depthStateGEqual = [m_device newDepthStencilStateWithDescriptor:desc];
	}
	// GREATER
	{
		MTLDepthStencilDescriptor* desc = [[MTLDepthStencilDescriptor alloc] init];
		desc.depthCompareFunction = MTLCompareFunctionGreater;
		desc.depthWriteEnabled = YES;
		m_depthStateGreater = [m_device newDepthStencilStateWithDescriptor:desc];
	}
	// Disabled with write
	{
		MTLDepthStencilDescriptor* desc = [[MTLDepthStencilDescriptor alloc] init];
		desc.depthCompareFunction = MTLCompareFunctionAlways;
		desc.depthWriteEnabled = YES;
		m_depthDisabledWrite = [m_device newDepthStencilStateWithDescriptor:desc];
	}
	// Disabled no write
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

void CGSH_Metal::MarkNewFrame()
{
	CGSHandler::MarkNewFrame();
}

// ============================================================
// WriteRegisterImpl - Handle GS register writes
// Follows the same pattern as the Vulkan backend
// ============================================================
void CGSH_Metal::WriteRegisterImpl(uint8 registerId, uint64 data)
{
	// Handle incomplete transfers (games like Silent Hill 2)
	if(!m_xferBuffer.empty() && (registerId != GS_REG_HWREG))
	{
		ProcessHostToLocalTransfer();
	}

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
// VertexKick - Accumulate vertices and trigger primitive drawing
// Uses countdown approach matching Vulkan backend exactly
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
// ProcessPrim - Start a new primitive type
// ============================================================
void CGSH_Metal::ProcessPrim(uint64 data)
{
	auto prim = make_convertible<PRIM>(data);

	// If changing prim type, we need to flush accumulated vertices
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
// SetRenderingContext - Read state from GS registers
// ============================================================
void CGSH_Metal::SetRenderingContext(uint64 primReg)
{
	auto prim = make_convertible<PRMODE>(primReg);
	unsigned int context = prim.nContext;

	// XY offset
	auto offset = make_convertible<XYOFFSET>(m_nReg[GS_REG_XYOFFSET_1 + context]);
	m_primOfsX = offset.GetX();
	m_primOfsY = offset.GetY();

	// Frame buffer
	auto frame = make_convertible<FRAME>(m_nReg[GS_REG_FRAME_1 + context]);
	m_fbBasePtr = frame.GetBasePtr();
	m_fbWidth = frame.GetWidth();

	// Depth buffer
	auto zbuf = make_convertible<ZBUF>(m_nReg[GS_REG_ZBUF_1 + context]);
	m_depthWriteEnabled = (zbuf.nMask == 0);

	// Test register
	auto test = make_convertible<TEST>(m_nReg[GS_REG_TEST_1 + context]);
	m_depthEnabled = test.nDepthEnabled != 0;
	m_depthTestMethod = test.nDepthMethod;
	m_alphaTestEnabled = test.nAlphaEnabled != 0;
	m_alphaTestMethod = test.nAlphaMethod;
	m_alphaTestRef = test.nAlphaRef;
	m_alphaTestFail = test.nAlphaFail;

	// Alpha blending
	auto alpha = make_convertible<ALPHA>(m_nReg[GS_REG_ALPHA_1 + context]);
	m_alphaA = alpha.nA;
	m_alphaB = alpha.nB;
	m_alphaC = alpha.nC;
	m_alphaD = alpha.nD;
	m_alphaFix = alpha.nFix;

	// Scissor
	auto scissor = make_convertible<SCISSOR>(m_nReg[GS_REG_SCISSOR_1 + context]);
	m_scissorLeft = scissor.scax0;
	m_scissorTop = scissor.scay0;
	m_scissorRight = scissor.scax1;
	m_scissorBottom = scissor.scay1;

	// Texture
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

		// Sync CLUT if needed for indexed textures
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

	// Fog color
	auto fogCol = make_convertible<FOGCOL>(m_nReg[GS_REG_FOGCOL]);
	m_fogR = (float)fogCol.nFCR / 255.0f;
	m_fogG = (float)fogCol.nFCG / 255.0f;
	m_fogB = (float)fogCol.nFCB / 255.0f;
}

// ============================================================
// EmitVertex helper
// ============================================================
void CGSH_Metal::EmitVertex(const VERTEX& vtx, float screenW, float screenH)
{
	if(m_currentVertex >= MAX_VERTICES)
	{
		FlushVertices();
	}

	auto& mv = m_mappedVertices[m_currentVertex++];

	// Decode position
	bool isXYZF = false; // Position already decoded in VertexKick
	auto xyz = make_convertible<XYZ>(vtx.position);
	float posX = xyz.GetX() - m_primOfsX;
	float posY = xyz.GetY() - m_primOfsY;
	float posZ = (float)xyz.nZ / 4294967296.0f;

	// Convert to NDC (-1..1)
	float x = posX / screenW * 2.0f - 1.0f;
	float y = -(posY / screenH * 2.0f - 1.0f);

	mv.position[0] = x;
	mv.position[1] = y;
	mv.position[2] = posZ;
	mv.position[3] = 1.0f;

	// Color
	auto rgbaq = make_convertible<RGBAQ>(vtx.rgbaq);
	mv.color[0] = (float)rgbaq.nR / 255.0f;
	mv.color[1] = (float)rgbaq.nG / 255.0f;
	mv.color[2] = (float)rgbaq.nB / 255.0f;
	mv.color[3] = (float)rgbaq.nA / 128.0f;

	// Texture coordinates
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
// Prim_Point - Render a point as a small degenerate triangle
// ============================================================
void CGSH_Metal::Prim_Point()
{
	auto& vtx = m_vtxBuffer[0];
	float screenW = m_screenWidth;
	float screenH = m_screenHeight;

	// Emit as a tiny triangle (3 vertices at same position)
	EmitVertex(vtx, screenW, screenH);
	EmitVertex(vtx, screenW, screenH);
	EmitVertex(vtx, screenW, screenH);

	// Nudge the last two vertices by a subpixel amount to avoid degenerate
	if(m_currentVertex >= 3)
	{
		m_mappedVertices[m_currentVertex - 2].position[0] += 2.0f / screenW;
		m_mappedVertices[m_currentVertex - 1].position[1] += 2.0f / screenH;
	}
}

// ============================================================
// Prim_Line - Render a line as a thin quad (2 triangles)
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

	// Compute a perpendicular offset for line width
	float dx = x1 - x0;
	float dy = y1 - y0;
	float len = sqrtf(dx * dx + dy * dy);
	if(len < 0.001f) len = 0.001f;

	// Line half-width in pixels (minimum 0.5)
	float hw = 0.5f;
	float nx = -dy / len * hw;
	float ny = dx / len * hw;

	// Build 4 corners of the line quad
	VERTEX corners[4];
	memcpy(&corners[0], &vtx0, sizeof(VERTEX));
	memcpy(&corners[1], &vtx0, sizeof(VERTEX));
	memcpy(&corners[2], &vtx1, sizeof(VERTEX));
	memcpy(&corners[3], &vtx1, sizeof(VERTEX));

	// Emit two triangles: 0-1-2, 1-2-3
	EmitVertex(vtx0, screenW, screenH);
	EmitVertex(vtx0, screenW, screenH);
	EmitVertex(vtx1, screenW, screenH);

	// Offset the vertices to form a quad
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
// Prim_Triangle - Render a triangle
// ============================================================
void CGSH_Metal::Prim_Triangle()
{
	float screenW = m_screenWidth;
	float screenH = m_screenHeight;

	// vtxBuffer[2] = first vertex kicked, [0] = last
	EmitVertex(m_vtxBuffer[2], screenW, screenH);
	EmitVertex(m_vtxBuffer[1], screenW, screenH);
	EmitVertex(m_vtxBuffer[0], screenW, screenH);
}

// ============================================================
// Prim_Sprite - Render a sprite as 2 triangles
// ============================================================
void CGSH_Metal::Prim_Sprite()
{
	float screenW = m_screenWidth;
	float screenH = m_screenHeight;

	auto& vtx0 = m_vtxBuffer[1]; // first vertex
	auto& vtx1 = m_vtxBuffer[0]; // second vertex

	auto xyz0 = make_convertible<XYZ>(vtx0.position);
	auto xyz1 = make_convertible<XYZ>(vtx1.position);
	float x0 = (xyz0.GetX() - m_primOfsX) / screenW * 2.0f - 1.0f;
	float y0 = -((xyz0.GetY() - m_primOfsY) / screenH * 2.0f - 1.0f);
	float x1 = (xyz1.GetX() - m_primOfsX) / screenW * 2.0f - 1.0f;
	float y1 = -((xyz1.GetY() - m_primOfsY) / screenH * 2.0f - 1.0f);
	float z = (float)xyz1.nZ / 4294967296.0f;

	// Use second vertex's color (sprite uses flat shading from v1)
	auto rgbaq = make_convertible<RGBAQ>(vtx1.rgbaq);
	float r = (float)rgbaq.nR / 255.0f;
	float g = (float)rgbaq.nG / 255.0f;
	float b = (float)rgbaq.nB / 255.0f;
	float a = (float)rgbaq.nA / 128.0f;

	// Texture coords
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

	// Triangle 1
	emitSpriteVertex(x0, y0, u0, v0);
	emitSpriteVertex(x1, y0, u1, v0);
	emitSpriteVertex(x0, y1, u0, v1);

	// Triangle 2
	emitSpriteVertex(x1, y0, u1, v0);
	emitSpriteVertex(x1, y1, u1, v1);
	emitSpriteVertex(x0, y1, u0, v1);
}

// ============================================================
// FlushVertices - Submit accumulated vertices to GPU
// ============================================================
void CGSH_Metal::FlushVertices()
{
	if(m_currentVertex == 0) return;

	// Upload GS memory to the Metal buffer
	UploadGSMemory();

	id<MTLCommandBuffer> commandBuffer = [m_commandQueue commandBuffer];
	if(!commandBuffer) return;

	// Ensure we have render targets
	if(m_presentColorTexture == nil)
	{
		if(m_presentWidth == 0 || m_presentHeight == 0)
		{
			m_presentWidth = (uint32)m_screenWidth;
			m_presentHeight = (uint32)m_screenHeight;
		}
		CreatePresentRenderTargets(m_presentWidth, m_presentHeight);
		if(m_presentColorTexture == nil)
		{
			m_currentVertex = 0;
			return;
		}
	}

	MTLRenderPassDescriptor* renderPass = [MTLRenderPassDescriptor renderPassDescriptor];
	renderPass.colorAttachments[0].texture = m_presentColorTexture;
	renderPass.colorAttachments[0].loadAction = MTLLoadActionLoad;
	renderPass.colorAttachments[0].storeAction = MTLStoreActionStore;
	renderPass.depthAttachment.texture = m_presentDepthTexture;
	renderPass.depthAttachment.loadAction = MTLLoadActionLoad;
	renderPass.depthAttachment.storeAction = MTLStoreActionStore;

	id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPass];

	// Select pipeline
	[encoder setRenderPipelineState:m_drawIsTextured ? m_drawPipelineTextured : m_drawPipelineFlat];

	// Select depth state based on current test register
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
	[encoder setDepthStencilState:depthState];

	// Set scissor rect
	MTLScissorRect scissorRect;
	scissorRect.x = m_scissorLeft;
	scissorRect.y = m_scissorTop;
	scissorRect.width = (m_scissorRight > m_scissorLeft) ? (m_scissorRight - m_scissorLeft + 1) : m_presentWidth;
	scissorRect.height = (m_scissorBottom > m_scissorTop) ? (m_scissorBottom - m_scissorTop + 1) : m_presentHeight;
	// Clamp to render target size
	if(scissorRect.x + scissorRect.width > m_presentWidth)
		scissorRect.width = m_presentWidth - scissorRect.x;
	if(scissorRect.y + scissorRect.height > m_presentHeight)
		scissorRect.height = m_presentHeight - scissorRect.y;
	if(scissorRect.width > 0 && scissorRect.height > 0)
	{
		[encoder setScissorRect:scissorRect];
	}

	// Set vertex buffer
	[encoder setVertexBuffer:m_vertexBuffer offset:0 atIndex:0];

	// Build uniforms for fragment shader
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

	[encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];

	if(m_drawIsTextured)
	{
		[encoder setFragmentBuffer:m_gsMemoryBuffer offset:0 atIndex:1];
		[encoder setFragmentBuffer:m_clutBuffer offset:0 atIndex:2];
		[encoder setFragmentBuffer:m_swizzleTablePSMCT32 offset:0 atIndex:3];
		[encoder setFragmentBuffer:m_swizzleTablePSMCT16 offset:0 atIndex:4];
		[encoder setFragmentBuffer:m_swizzleTablePSMT8 offset:0 atIndex:5];
	}

	[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:m_currentVertex];
	[encoder endEncoding];

	[commandBuffer commit];
	[commandBuffer waitUntilCompleted];

	m_currentVertex = 0;
}

void CGSH_Metal::UploadGSMemory()
{
	if(!m_memoryCache || !m_gsMemoryBuffer) return;
	memcpy([m_gsMemoryBuffer contents], m_memoryCache, GS_RAM_SIZE);
}

// ============================================================
// SyncCLUT - Read CLUT data from GS memory for indexed textures
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
		// 32-bit CLUT entries
		CGsPixelFormats::CPixelIndexorPSMCT32 indexor(m_memoryCache, clutPtr, 1);
		for(uint32 i = 0; i < clutEntryCount; i++)
		{
			uint32 color = indexor.GetPixel(i + csa * 16, 0);
			clutDst[i] = color;
		}
	}
	else if(cpsm == PSMCT16 || cpsm == PSMCT16S)
	{
		// 16-bit CLUT entries, convert to 32-bit
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
// FlipImpl - Called when the frame is done
// ============================================================
void CGSH_Metal::FlipImpl(const DISPLAY_INFO& dispInfo)
{
	FlushVertices();

	// Update screen size from display info
	if(dispInfo.width > 0 && dispInfo.height > 0)
	{
		m_screenWidth = (float)dispInfo.width;
		m_screenHeight = (float)dispInfo.height;
	}

	DoPresent(dispInfo);
	CGSHandler::FlipImpl(dispInfo);
}

// ============================================================
// DoPresent - Read from GS memory and display on screen
// ============================================================
void CGSH_Metal::DoPresent(const DISPLAY_INFO& dispInfo)
{
	if(!m_metalLayer) return;

	@autoreleasepool
	{
		m_currentDrawable = [m_metalLayer nextDrawable];
		if(!m_currentDrawable) return;

		UploadGSMemory();

		id<MTLCommandBuffer> commandBuffer = [m_commandQueue commandBuffer];
		if(!commandBuffer) return;

		MTLRenderPassDescriptor* renderPass = [MTLRenderPassDescriptor renderPassDescriptor];
		renderPass.colorAttachments[0].texture = [m_currentDrawable texture];
		renderPass.colorAttachments[0].loadAction = MTLLoadActionClear;
		renderPass.colorAttachments[0].storeAction = MTLStoreActionStore;
		renderPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);

		id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPass];

		// Present each display layer
		for(unsigned int i = 0; i < DISPLAY_INFO::MAX_LAYERS; i++)
		{
			if(!dispInfo.layers[i].enabled) continue;

			auto& layer = dispInfo.layers[i];

			PresentUniforms uniforms = {};
			uniforms.srcSize = simd_make_float2(layer.width, layer.height);
			uniforms.dstSize = simd_make_float2(m_presentWidth, m_presentHeight);
			uniforms.fbPtr = layer.bufPtr;
			uniforms.fbWidth = layer.bufWidth;
			uniforms.fbPsm = layer.psm;

			[encoder setRenderPipelineState:m_presentPipeline];
			[encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
			[encoder setFragmentBuffer:m_gsMemoryBuffer offset:0 atIndex:1];
			[encoder setFragmentBuffer:m_swizzleTablePSMCT32 offset:0 atIndex:2];
			[encoder setFragmentBuffer:m_swizzleTablePSMCT16 offset:0 atIndex:3];
			[encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
		}

		[encoder endEncoding];
		[commandBuffer presentDrawable:m_currentDrawable];
		[commandBuffer commit];

		m_currentDrawable = nil;
	}
}

// ============================================================
// Transfer operations
// ============================================================
void CGSH_Metal::ProcessHostToLocalTransfer()
{
	if(m_xferBuffer.empty()) return;

	FlushVertices();

	// Delegate to base class which handles all PSM formats using
	// the write handlers and writes to m_pRAM
	CGSHandler::ProcessHostToLocalTransfer();

	// Copy affected area from m_pRAM to our memory cache
	if(m_pRAM && m_memoryCache)
	{
		memcpy(m_memoryCache, m_pRAM, GS_RAM_SIZE);
	}

	m_xferBuffer.clear();
}

void CGSH_Metal::ProcessLocalToHostTransfer()
{
	// Sync our memory cache back to RAM first
	if(m_pRAM && m_memoryCache)
	{
		memcpy(m_pRAM, m_memoryCache, GS_RAM_SIZE);
	}

	CGSHandler::ProcessLocalToHostTransfer();
}

void CGSH_Metal::ProcessLocalToLocalTransfer()
{
	FlushVertices();

	// Sync memory before transfer
	if(m_pRAM && m_memoryCache)
	{
		memcpy(m_pRAM, m_memoryCache, GS_RAM_SIZE);
	}

	CGSHandler::ProcessLocalToLocalTransfer();

	// Copy back after transfer
	if(m_pRAM && m_memoryCache)
	{
		memcpy(m_memoryCache, m_pRAM, GS_RAM_SIZE);
	}
}

void CGSH_Metal::ProcessClutTransfer(uint32 csa, uint32 csm)
{
	// Base class writes CLUT data to m_pCLUT
	// We don't need to do anything special here - SyncCLUT reads directly from GS memory
}

void CGSH_Metal::BeginTransferWrite()
{
	m_xferBuffer.clear();
}

void CGSH_Metal::TransferWrite(const uint8* buffer, uint32 length)
{
	m_xferBuffer.insert(m_xferBuffer.end(), buffer, buffer + length);
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
