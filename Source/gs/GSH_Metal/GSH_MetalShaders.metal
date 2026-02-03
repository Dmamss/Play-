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
