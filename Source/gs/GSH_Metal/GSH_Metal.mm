#import "GSH_Metal.h"
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <simd/simd.h>
#include "../../gs/GsPixelFormats.h"
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
	uint32_t texWidth;
	uint32_t texPsm;
	uint32_t clutBasePtr;
	uint32_t clutPsm;
	uint32_t alphaRef;
	uint32_t alphaFunc;
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
    , m_depthLessEqual(nil)
    , m_depthAlways(nil)
    , m_depthDisabled(nil)
    , m_samplerNearest(nil)
    , m_samplerBilinear(nil)
    , m_gsMemoryBuffer(nil)
    , m_clutBuffer(nil)
    , m_swizzleTablePSMCT32(nil)
    , m_swizzleTablePSMCT16(nil)
    , m_swizzleTablePSMT8(nil)
    , m_swizzleTablePSMT4(nil)
    , m_presentColorTexture(nil)
    , m_presentDepthTexture(nil)
    , m_vertexBuffer(nil)
    , m_currentDrawable(nil)
    , m_metalLayer(nil)
{
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
	CreatePresentRenderTargets(m_presentWidth, m_presentHeight);
}

void CGSH_Metal::InitializeImpl()
{
	CreateDevice();
	CreateBuffers();
	CreatePipelineStates();
	CreateDepthStencilStates();
	CreateSamplerStates();
	CreateSwizzleTables();

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
	m_depthLessEqual = nil;
	m_depthAlways = nil;
	m_depthDisabled = nil;
	m_samplerNearest = nil;
	m_samplerBilinear = nil;
	m_gsMemoryBuffer = nil;
	m_clutBuffer = nil;
	m_swizzleTablePSMCT32 = nil;
	m_swizzleTablePSMCT16 = nil;
	m_swizzleTablePSMT8 = nil;
	m_swizzleTablePSMT4 = nil;
	m_presentColorTexture = nil;
	m_presentDepthTexture = nil;
	m_vertexBuffer = nil;
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

	// CLUT buffer (1024 entries * 4 bytes)
	m_clutBuffer = [m_device newBufferWithLength:1024 * sizeof(uint32_t)
	                                     options:MTLResourceStorageModeShared];

	// Vertex buffer
	m_vertexBuffer = [m_device newBufferWithLength:VERTEX_BUFFER_SIZE
	                                       options:MTLResourceStorageModeShared];
	m_mappedVertices = static_cast<MetalVertex*>([m_vertexBuffer contents]);
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

// Flat (untextured) drawing
vertex VertexOut vs_draw(VertexIn in [[stage_in]]) {
    VertexOut out;
    out.position = in.position;
    out.texcoord = in.texcoord;
    out.color = in.color;
    out.fog = in.fog;
    return out;
}

fragment float4 fs_draw_flat(VertexOut in [[stage_in]]) {
    return in.color;
}

// Textured drawing - reads from GS memory buffer
struct DrawUniforms {
    float2 texSize;
    float2 screenSize;
    float alphaFix;
    uint fbBasePtr;
    uint fbWidth;
    uint texBasePtr;
    uint texWidth;
    uint texPsm;
    uint clutBasePtr;
    uint clutPsm;
    uint alphaRef;
    uint alphaFunc;
};

fragment float4 fs_draw_textured(VertexOut in [[stage_in]],
                                  constant DrawUniforms& uniforms [[buffer(0)]],
                                  constant uint* gsMemory [[buffer(1)]],
                                  constant uint* clutData [[buffer(2)]]) {
    // Simple PSMCT32 texture fetch from GS memory
    int2 texCoord = int2(in.texcoord);
    texCoord.x = clamp(texCoord.x, 0, int(uniforms.texSize.x) - 1);
    texCoord.y = clamp(texCoord.y, 0, int(uniforms.texSize.y) - 1);

    uint address = uniforms.texBasePtr + (texCoord.y * uniforms.texWidth + texCoord.x);
    uint wordAddr = address / 4;
    uint pixel = 0;
    if(wordAddr < 1048576) { // 4MB / 4
        pixel = gsMemory[wordAddr];
    }

    float4 texColor;
    texColor.r = float((pixel >>  0) & 0xFF) / 255.0;
    texColor.g = float((pixel >>  8) & 0xFF) / 255.0;
    texColor.b = float((pixel >> 16) & 0xFF) / 255.0;
    texColor.a = float((pixel >> 24) & 0xFF) / 128.0;

    return texColor * in.color;
}

// Present pass - reads framebuffer from GS memory and displays it
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
                           constant uint* gsMemory [[buffer(1)]]) {
    int2 coord = int2(in.texcoord * uniforms.srcSize);
    coord.x = clamp(coord.x, 0, int(uniforms.srcSize.x) - 1);
    coord.y = clamp(coord.y, 0, int(uniforms.srcSize.y) - 1);

    // Block-based addressing for PSMCT32 (simplified - page/block swizzle)
    uint pageWidth = 64;
    uint pageHeight = 32;
    uint blockWidth = 8;
    uint blockHeight = 8;

    uint pageX = coord.x / pageWidth;
    uint pageY = coord.y / pageHeight;
    uint page = pageY * (uniforms.fbWidth / pageWidth) + pageX;

    uint localX = coord.x % pageWidth;
    uint localY = coord.y % pageHeight;
    uint blockX = localX / blockWidth;
    uint blockY = localY / blockHeight;
    uint block = blockY * (pageWidth / blockWidth) + blockX;

    uint pixelX = localX % blockWidth;
    uint pixelY = localY % blockHeight;
    uint pixelInBlock = pixelY * blockWidth + pixelX;

    uint blocksPerPage = (pageWidth / blockWidth) * (pageHeight / blockHeight);
    uint pixelsPerBlock = blockWidth * blockHeight;

    uint address = uniforms.fbPtr / 4 + page * blocksPerPage * pixelsPerBlock + block * pixelsPerBlock + pixelInBlock;

    uint pixel = 0;
    if(address < 1048576) {
        pixel = gsMemory[address];
    }

    float4 color;
    if(uniforms.fbPsm == 0) { // PSMCT32
        color.r = float((pixel >>  0) & 0xFF) / 255.0;
        color.g = float((pixel >>  8) & 0xFF) / 255.0;
        color.b = float((pixel >> 16) & 0xFF) / 255.0;
        color.a = 1.0;
    } else if(uniforms.fbPsm == 2) { // PSMCT16
        color.r = float(((pixel >>  0) & 0x1F) << 3) / 255.0;
        color.g = float(((pixel >>  5) & 0x1F) << 3) / 255.0;
        color.b = float(((pixel >> 10) & 0x1F) << 3) / 255.0;
        color.a = 1.0;
    } else { // PSMCT24 and others
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
	{
		MTLDepthStencilDescriptor* desc = [[MTLDepthStencilDescriptor alloc] init];
		desc.depthCompareFunction = MTLCompareFunctionLessEqual;
		desc.depthWriteEnabled = YES;
		m_depthLessEqual = [m_device newDepthStencilStateWithDescriptor:desc];
	}
	{
		MTLDepthStencilDescriptor* desc = [[MTLDepthStencilDescriptor alloc] init];
		desc.depthCompareFunction = MTLCompareFunctionAlways;
		desc.depthWriteEnabled = YES;
		m_depthAlways = [m_device newDepthStencilStateWithDescriptor:desc];
	}
	{
		MTLDepthStencilDescriptor* desc = [[MTLDepthStencilDescriptor alloc] init];
		desc.depthCompareFunction = MTLCompareFunctionAlways;
		desc.depthWriteEnabled = NO;
		m_depthDisabled = [m_device newDepthStencilStateWithDescriptor:desc];
	}
}

void CGSH_Metal::CreateSamplerStates()
{
	{
		MTLSamplerDescriptor* desc = [[MTLSamplerDescriptor alloc] init];
		desc.minFilter = MTLSamplerMinMagFilterNearest;
		desc.magFilter = MTLSamplerMinMagFilterNearest;
		desc.sAddressMode = MTLSamplerAddressModeClampToEdge;
		desc.tAddressMode = MTLSamplerAddressModeClampToEdge;
		m_samplerNearest = [m_device newSamplerStateWithDescriptor:desc];
	}
	{
		MTLSamplerDescriptor* desc = [[MTLSamplerDescriptor alloc] init];
		desc.minFilter = MTLSamplerMinMagFilterLinear;
		desc.magFilter = MTLSamplerMinMagFilterLinear;
		desc.sAddressMode = MTLSamplerAddressModeClampToEdge;
		desc.tAddressMode = MTLSamplerAddressModeClampToEdge;
		m_samplerBilinear = [m_device newSamplerStateWithDescriptor:desc];
	}
}

void CGSH_Metal::CreateSwizzleTables()
{
	// Swizzle tables are used for PS2 GS memory layout -> linear conversion
	// For initial implementation, we handle this in the shaders with simplified addressing
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

void CGSH_Metal::VertexKick(uint8 registerId, uint64 data)
{
	if(m_pendingPrim)
	{
		m_pendingPrim = false;
		ProcessPrim(m_pendingPrimValue);
	}

	bool isDrawing = (registerId == GS_REG_XYZ2) || (registerId == GS_REG_XYZF2);

	auto& currentContext = m_nReg[GS_REG_PRIM];
	auto prim = make_convertible<PRIM>(currentContext);

	auto& vtx = m_vtxBuffer[m_vtxCount];
	vtx.position = data;
	vtx.rgbaq = m_nReg[GS_REG_RGBAQ];
	vtx.uv = m_nReg[GS_REG_UV];
	vtx.st = m_nReg[GS_REG_ST];
	if(registerId == GS_REG_XYZF2 || registerId == GS_REG_XYZF3)
	{
		auto xyzf = make_convertible<XYZF>(data);
		vtx.fog = xyzf.nF;
	}
	else
	{
		vtx.fog = static_cast<uint8>(m_nReg[GS_REG_FOG] >> 56);
	}

	m_vtxCount++;

	if(!isDrawing) return;

	switch(m_primitiveType)
	{
	case PRIM_POINT:
		if(m_vtxCount >= 1)
		{
			Prim_Point();
			m_vtxCount = 0;
		}
		break;
	case PRIM_LINE:
	case PRIM_LINESTRIP:
		if(m_vtxCount >= 2)
		{
			Prim_Line();
			m_vtxCount = 0;
		}
		break;
	case PRIM_TRIANGLE:
	case PRIM_TRIANGLESTRIP:
	case PRIM_TRIANGLEFAN:
		if(m_vtxCount >= 3)
		{
			Prim_Triangle();
			m_vtxCount = 0;
		}
		break;
	case PRIM_SPRITE:
		if(m_vtxCount >= 2)
		{
			Prim_Sprite();
			m_vtxCount = 0;
		}
		break;
	}
}

void CGSH_Metal::ProcessPrim(uint64 data)
{
	auto prim = make_convertible<PRIM>(data);
	m_primitiveType = prim.nType;
	m_primitiveMode <<= data;
	m_vtxCount = 0;
}

void CGSH_Metal::SetRenderingContext(uint64 primReg)
{
	auto prim = make_convertible<PRIM>(primReg);
	unsigned int context = prim.nContext;

	auto offset = make_convertible<XYOFFSET>(m_nReg[GS_REG_XYOFFSET_1 + context]);
	m_primOfsX = offset.GetX();
	m_primOfsY = offset.GetY();

	auto frame = make_convertible<FRAME>(m_nReg[GS_REG_FRAME_1 + context]);
	m_fbBasePtr = frame.GetBasePtr();

	auto tex0 = make_convertible<TEX0>(m_nReg[GS_REG_TEX0_1 + context]);
	m_texWidth = tex0.GetWidth();
	m_texHeight = tex0.GetHeight();
}

void CGSH_Metal::Prim_Point()
{
	// Points are rarely used, emit as degenerate triangle
}

void CGSH_Metal::Prim_Line()
{
	// Lines are rarely used, emit as thin triangle
}

void CGSH_Metal::Prim_Triangle()
{
	if(m_currentVertex + 3 > MAX_VERTICES) FlushVertices();

	SetRenderingContext(m_nReg[GS_REG_PRIM]);

	float screenW = 640.0f;
	float screenH = 448.0f;

	for(int i = 0; i < 3; i++)
	{
		auto& vtx = m_vtxBuffer[i];
		auto& mv = m_mappedVertices[m_currentVertex++];

		auto xyz = make_convertible<XYZ>(vtx.position);
		float posX = xyz.GetX();
		float posY = xyz.GetY();
		float posZ = (float)xyz.nZ / 4294967296.0f;

		float x = (posX - m_primOfsX) / screenW * 2.0f - 1.0f;
		float y = -((posY - m_primOfsY) / screenH * 2.0f - 1.0f);

		mv.position[0] = x;
		mv.position[1] = y;
		mv.position[2] = posZ;
		mv.position[3] = 1.0f;

		auto rgbaq = make_convertible<RGBAQ>(vtx.rgbaq);
		mv.color[0] = (float)rgbaq.nR / 255.0f;
		mv.color[1] = (float)rgbaq.nG / 255.0f;
		mv.color[2] = (float)rgbaq.nB / 255.0f;
		mv.color[3] = (float)rgbaq.nA / 128.0f;

		auto uv = make_convertible<UV>(vtx.uv);
		mv.texcoord[0] = (float)uv.GetU();
		mv.texcoord[1] = (float)uv.GetV();

		mv.fog = vtx.fog;
	}
}

void CGSH_Metal::Prim_Sprite()
{
	if(m_currentVertex + 6 > MAX_VERTICES) FlushVertices();

	SetRenderingContext(m_nReg[GS_REG_PRIM]);

	float screenW = 640.0f;
	float screenH = 448.0f;

	auto& vtx0 = m_vtxBuffer[0];
	auto& vtx1 = m_vtxBuffer[1];

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

	auto uv0 = make_convertible<UV>(vtx0.uv);
	auto uv1 = make_convertible<UV>(vtx1.uv);
	float u0 = (float)uv0.GetU();
	float v0 = (float)uv0.GetV();
	float u1 = (float)uv1.GetU();
	float v1 = (float)uv1.GetV();

	// Emit two triangles for the sprite quad
	auto emitVertex = [&](float x, float y, float u, float v) {
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
		mv.fog = 0.0f;
	};

	// Triangle 1: top-left, top-right, bottom-left
	emitVertex(x0, y0, u0, v0);
	emitVertex(x1, y0, u1, v0);
	emitVertex(x0, y1, u0, v1);

	// Triangle 2: top-right, bottom-right, bottom-left
	emitVertex(x1, y0, u1, v0);
	emitVertex(x1, y1, u1, v1);
	emitVertex(x0, y1, u0, v1);
}

void CGSH_Metal::FlushVertices()
{
	if(m_currentVertex == 0) return;

	// Upload GS memory to the Metal buffer
	UploadGSMemory();

	id<MTLCommandBuffer> commandBuffer = [m_commandQueue commandBuffer];
	if(!commandBuffer) return;

	if(m_presentColorTexture == nil) return;

	MTLRenderPassDescriptor* renderPass = [MTLRenderPassDescriptor renderPassDescriptor];
	renderPass.colorAttachments[0].texture = m_presentColorTexture;
	renderPass.colorAttachments[0].loadAction = MTLLoadActionLoad;
	renderPass.colorAttachments[0].storeAction = MTLStoreActionStore;
	renderPass.depthAttachment.texture = m_presentDepthTexture;
	renderPass.depthAttachment.loadAction = MTLLoadActionLoad;
	renderPass.depthAttachment.storeAction = MTLStoreActionStore;

	id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPass];

	bool textured = m_primitiveMode.nTexture;
	[encoder setRenderPipelineState:textured ? m_drawPipelineTextured : m_drawPipelineFlat];
	[encoder setDepthStencilState:m_depthTestingEnabled ? m_depthLessEqual : m_depthDisabled];
	[encoder setVertexBuffer:m_vertexBuffer offset:0 atIndex:0];

	if(textured)
	{
		DrawUniforms uniforms = {};
		uniforms.texSize = simd_make_float2(m_texWidth, m_texHeight);
		uniforms.screenSize = simd_make_float2(m_presentWidth, m_presentHeight);
		uniforms.fbBasePtr = m_fbBasePtr;
		[encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
		[encoder setFragmentBuffer:m_gsMemoryBuffer offset:0 atIndex:1];
		[encoder setFragmentBuffer:m_clutBuffer offset:0 atIndex:2];
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

void CGSH_Metal::FlipImpl(const DISPLAY_INFO& dispInfo)
{
	FlushVertices();
	DoPresent(dispInfo);
	CGSHandler::FlipImpl(dispInfo);
}

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
		for(int i = 0; i < 2; i++)
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
			[encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
		}

		[encoder endEncoding];
		[commandBuffer presentDrawable:m_currentDrawable];
		[commandBuffer commit];

		m_currentDrawable = nil;
	}
}

void CGSH_Metal::ProcessHostToLocalTransfer()
{
	// Copy transfer data from GS transfer buffer to our memory cache
	auto bltBuf = make_convertible<BITBLTBUF>(m_nReg[GS_REG_BITBLTBUF]);
	auto trxPos = make_convertible<TRXPOS>(m_nReg[GS_REG_TRXPOS]);
	auto trxReg = make_convertible<TRXREG>(m_nReg[GS_REG_TRXREG]);

	if(m_xferBuffer.empty()) return;

	auto dstPtr = bltBuf.GetDstPtr();
	auto dstWidth = bltBuf.GetDstWidth();

	// Simple linear copy for PSMCT32
	CGSHandler::ProcessHostToLocalTransfer();
}

void CGSH_Metal::ProcessLocalToHostTransfer()
{
	CGSHandler::ProcessLocalToHostTransfer();
}

void CGSH_Metal::ProcessLocalToLocalTransfer()
{
	CGSHandler::ProcessLocalToLocalTransfer();
}

void CGSH_Metal::ProcessClutTransfer(uint32 csa, uint32 csm)
{
	// Copy CLUT data from GS memory to our CLUT buffer
	if(m_clutBuffer && m_memoryCache)
	{
		// CLUT is stored in GS memory, copy to dedicated buffer for shader access
		memcpy([m_clutBuffer contents], m_memoryCache + (csa * 256), std::min(1024u * 4u, (uint32)(GS_RAM_SIZE - csa * 256)));
	}
}

void CGSH_Metal::SyncCLUT(const TEX0& tex0)
{
	// Sync CLUT data for texture lookups
}

void CGSH_Metal::BeginTransferWrite()
{
	m_xferBuffer.clear();
}

void CGSH_Metal::TransferWrite(const uint8* buffer, uint32 length)
{
	m_xferBuffer.insert(m_xferBuffer.end(), buffer, buffer + length);
}
