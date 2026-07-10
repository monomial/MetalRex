#include <metal_stdlib>
using namespace metal;

struct RexUniforms {
    float4x4 mvp;
    float4 color;
};

struct RexVertexOut {
    float4 position [[position]];
    float4 color;
};

struct RexVertex {
    float3 position;
};

vertex RexVertexOut rex_vertex(uint vertexID [[vertex_id]],
                               const device RexVertex *vertices [[buffer(0)]],
                               constant RexUniforms& uniforms [[buffer(1)]]) {
    RexVertexOut out;
    out.position = uniforms.mvp * float4(vertices[vertexID].position, 1.0);
    out.color = uniforms.color;
    return out;
}

fragment float4 rex_fragment(RexVertexOut in [[stage_in]]) {
    return in.color;
}

// ---------------------------------------------------------------------------
// Textured 2D overlay — CoreGraphics/CoreText-generated HUD panels (GAME
// OVER / continue prompt). Vertices are a unit quad in [-0.5, 0.5]; the
// model/projection baked into the mvp scales+positions it in overlay-pixel
// space, same convention as rex_vertex above.
// ---------------------------------------------------------------------------

struct RexTextureUniforms {
    float4x4 mvp;
};

struct RexTextureOut {
    float4 position [[position]];
    float2 uv;
};

vertex RexTextureOut rex_texture_vertex(uint vertexID [[vertex_id]],
                                        const device RexVertex *vertices [[buffer(0)]],
                                        constant RexTextureUniforms& uniforms [[buffer(1)]]) {
    RexTextureOut out;
    float3 p = vertices[vertexID].position;
    out.position = uniforms.mvp * float4(p, 1.0);
    // CGBitmapContextCreate draws with (0,0) at the image's logical bottom
    // but writes row 0 of the buffer first — the opposite of this shader's
    // +Y-up overlay convention (Rex_make_ortho, no sign flip) — so the V
    // axis must flip here rather than copying MetalBrawler's unflipped
    // mapping (its HUD ortho already bakes in a -Y scale that this one
    // doesn't share).
    out.uv = float2(p.x + 0.5, 0.5 - p.y);
    return out;
}

fragment float4 rex_texture_fragment(RexTextureOut in [[stage_in]],
                                     texture2d<float> tex [[texture(0)]],
                                     sampler s [[sampler(0)]]) {
    return tex.sample(s, in.uv);
}
