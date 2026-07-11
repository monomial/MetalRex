#include <metal_stdlib>
using namespace metal;

struct RexUniforms {
    float4x4 mvp;
    float4 color;
};

struct RexVertexOut {
    float4 position [[position]];
    float4 color;
    float viewDepth;
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
    // Perspective draws carry view depth in clip w; the HUD's orthographic
    // draws land at w == 1, safely below the fog ramp's start, so overlay
    // elements are structurally exempt from fog without a separate pipeline.
    out.viewDepth = out.position.w;
    return out;
}

fragment float4 rex_fragment(RexVertexOut in [[stage_in]]) {
    // Distance fog toward the sky's horizon haze: cheap aerial perspective
    // that seats the distant treeline ridge into the sky gradient instead
    // of leaving a hard silhouette edge.
    const float3 fogColor = float3(0.87, 0.86, 0.76);
    const float fogStart = 16.0;
    const float fogEnd = 80.0;
    const float maxFog = 0.88;
    float fogT = clamp((in.viewDepth - fogStart) / (fogEnd - fogStart), 0.0, 1.0) * maxFog;
    return float4(mix(in.color.rgb, fogColor, fogT), in.color.a);
}

// ---------------------------------------------------------------------------
// Textured 2D overlay — CoreGraphics/CoreText-generated HUD panels (GAME
// OVER / continue prompt). Vertices are a unit quad in [-0.5, 0.5]; the
// model/projection baked into the mvp scales+positions it in overlay-pixel
// space, same convention as rex_vertex above.
// ---------------------------------------------------------------------------

struct RexTextureUniforms {
    float4x4 mvp;
    float alpha; // whole-quad fade (score popups); 1.0 for opaque HUD panels
};

struct RexTextureOut {
    float4 position [[position]];
    float2 uv;
    float alpha;
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
    out.alpha = uniforms.alpha;
    return out;
}

fragment float4 rex_texture_fragment(RexTextureOut in [[stage_in]],
                                     texture2d<float> tex [[texture(0)]],
                                     sampler s [[sampler(0)]]) {
    // Premultiplied content: scaling the whole sample by alpha fades both
    // color and coverage together.
    return tex.sample(s, in.uv) * in.alpha;
}
