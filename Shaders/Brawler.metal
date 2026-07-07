#include <metal_stdlib>
using namespace metal;

// Matches DrawUniforms in GameViewController.mm — pushed via setVertexBytes:.
struct Uniforms {
    float4x4 mvp;
    float4   color;
};

struct VertexIn {
    float3 position [[attribute(0)]];
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
};

vertex VertexOut vertex_main(VertexIn in [[stage_in]],
                             constant Uniforms& u [[buffer(1)]]) {
    VertexOut out;
    out.position = u.mvp * float4(in.position, 1.0);
    out.color    = u.color;
    return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]]) {
    return in.color;
}

// ---------------------------------------------------------------------------
// Textured 2D overlay — CoreGraphics-generated phase/menu panels.
// ---------------------------------------------------------------------------

struct TextureUniforms {
    float4x4 mvp;
};

struct TextureOut {
    float4 position [[position]];
    float2 uv;
};

vertex TextureOut texture_vertex(VertexIn in [[stage_in]],
                                 constant TextureUniforms& u [[buffer(1)]]) {
    TextureOut out;
    out.position = u.mvp * float4(in.position, 1.0);
    out.uv = float2(in.position.x + 0.5, in.position.y + 0.5);
    return out;
}

fragment float4 texture_fragment(TextureOut in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]],
                                 sampler s [[sampler(0)]]) {
    return tex.sample(s, in.uv);
}

// ---------------------------------------------------------------------------
// Floor — asphalt base with subtle pavement seams, road markings, sidewalk
// bands, and a soft radial darkening toward the room edges.
// ---------------------------------------------------------------------------

struct FloorUniforms {            // matches FloorUniformsGPU in BrawlerRenderer.mm
    float4x4 mvp;
    float4   baseColor;
    float4   lineColor;
    float4   marking;
    float2   center;              // room center (world)
    float2   size;                // room extents (world)
};

struct FloorOut {
    float4 position [[position]];
    float2 world;
    float4 base;
    float4 line;
    float4 marking;
    float2 center;
    float2 halfSize;
};

vertex FloorOut floor_vertex(VertexIn in [[stage_in]],
                             constant FloorUniforms& u [[buffer(1)]]) {
    FloorOut out;
    out.position = u.mvp * float4(in.position, 1.0);
    out.world    = in.position.xy * u.size + u.center;
    out.base     = u.baseColor;
    out.line     = u.lineColor;
    out.marking  = u.marking;
    out.center   = u.center;
    out.halfSize = u.size * 0.5;
    return out;
}

fragment float4 floor_fragment(FloorOut in [[stage_in]]) {
    // Pavement expansion joints: wider and fainter than the old arena grid.
    const float cell = 250.0;
    float2 g  = abs(fract(in.world / cell + 0.5) - 0.5) * cell;
    float dist = min(g.x, g.y);
    float lineMix = 1.0 - smoothstep(1.0, 4.0, dist);

    float3 c = mix(in.base.rgb, in.line.rgb, lineMix * 0.25);

    // Vignette toward room edges grounds the arena in the void around it.
    float2 rel = abs(in.world - in.center) / in.halfSize; // 0 center → 1 edge
    float edgeCoord = max(rel.x, rel.y);
    float curb = smoothstep(0.80, 0.835, edgeCoord) * (1.0 - smoothstep(0.90, 0.92, edgeCoord));
    c = mix(c, float3(0.55, 0.55, 0.58), curb * 0.32);

    float lane = 1.0 - smoothstep(4.0, 6.5, abs(in.world.x - in.center.x));
    float dashPhase = fmod(in.world.y - in.center.y + 6000.0, 120.0);
    float dash = 1.0 - smoothstep(68.0, 72.0, dashPhase);
    c = mix(c, in.marking.rgb, lane * dash * 0.52);

    float edge = smoothstep(0.55, 1.05, edgeCoord);
    c *= (1.0 - 0.35 * edge);

    return float4(c, 1.0);
}

// ---------------------------------------------------------------------------
// Blob shadow — soft dark circle under each character. Uses the same unit
// quad as the flat pipeline; quad-local xy (±0.5) becomes the falloff radius.
// Drawn with alpha blending, depth-write off.
// ---------------------------------------------------------------------------

struct ShadowOut {
    float4 position [[position]];
    float2 local;
    float  alpha;
};

vertex ShadowOut shadow_vertex(VertexIn in [[stage_in]],
                               constant Uniforms& u [[buffer(1)]]) {
    ShadowOut out;
    out.position = u.mvp * float4(in.position, 1.0);
    out.local    = in.position.xy;   // unit quad: -0.5 … +0.5
    out.alpha    = u.color.a;        // overall shadow strength
    return out;
}

fragment float4 shadow_fragment(ShadowOut in [[stage_in]]) {
    float r = length(in.local) * 2.0;             // 0 center → 1 at quad edge
    float a = smoothstep(1.0, 0.45, r) * in.alpha; // soft edge, solid core
    return float4(0.0, 0.0, 0.0, a);
}

// ---------------------------------------------------------------------------
// Particles — camera-facing billboards, additive blending. One instance per
// particle; the unit quad supplies the corner offsets.
// ---------------------------------------------------------------------------

struct ParticleInstance {       // matches ParticleInstanceGPU in BrawlerRenderer.mm
    float3 pos;
    float  size;
    float4 color;               // rgb premultiplied by fade, a = fade
};

struct ParticleUniforms {       // matches ParticleUniformsGPU in BrawlerRenderer.mm
    float4x4 vp;
    float3   camRight;
    float3   camUp;
};

struct ParticleOut {
    float4 position [[position]];
    float2 local;
    float4 color;
};

vertex ParticleOut particle_vertex(VertexIn in [[stage_in]],
                                   constant ParticleInstance *instances [[buffer(1)]],
                                   constant ParticleUniforms &u         [[buffer(2)]],
                                   uint iid [[instance_id]])
{
    ParticleInstance p = instances[iid];
    float3 world = p.pos + (u.camRight * in.position.x + u.camUp * in.position.y) * p.size;
    ParticleOut out;
    out.position = u.vp * float4(world, 1.0);
    out.local    = in.position.xy;
    out.color    = p.color;
    return out;
}

fragment float4 particle_fragment(ParticleOut in [[stage_in]]) {
    float r = length(in.local) * 2.0;
    float glow = smoothstep(1.0, 0.0, r);
    glow *= glow;                                  // hot core, fast falloff
    return float4(in.color.rgb * glow * in.color.a, 1.0); // additive: alpha unused
}

// ---------------------------------------------------------------------------
// Post-process — fullscreen pass over the offscreen scene texture:
// radial blur toward screen center on hits, red edge vignette on damage.
// ---------------------------------------------------------------------------

struct PostUniforms {              // matches PostUniformsGPU in BrawlerRenderer.mm
    float hitBlur;                 // 0..1, decays ~0.15s after a hit
    float damageFlash;             // 0..1, decays ~0.35s after the player is hit
};

struct PostOut {
    float4 position [[position]];
    float2 uv;
};

vertex PostOut post_vertex(uint vid [[vertex_id]]) {
    // Single fullscreen triangle.
    float2 pos[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    PostOut o;
    o.position = float4(pos[vid], 0.0, 1.0);
    o.uv = float2(pos[vid].x * 0.5 + 0.5, 1.0 - (pos[vid].y * 0.5 + 0.5));
    return o;
}

fragment float4 post_fragment(PostOut in [[stage_in]],
                              texture2d<float> scene [[texture(0)]],
                              sampler           s    [[sampler(0)]],
                              constant PostUniforms& u [[buffer(0)]])
{
    float3 c = scene.sample(s, in.uv).rgb;

    // Radial blur: extra taps marching toward screen center, scaled by hit
    // strength. Cheap (5 taps) and only sampled while a hit is fresh.
    if (u.hitBlur > 0.003) {
        float2 toCenter = float2(0.5, 0.5) - in.uv;
        float3 acc = c;
        for (int i = 1; i <= 5; i++) {
            float t = (float)i * (0.035 / 5.0) * u.hitBlur;
            acc += scene.sample(s, in.uv + toCenter * t).rgb;
        }
        c = acc / 6.0;
    }

    // Damage vignette: red bleed from the screen edges.
    float2 d   = abs(in.uv - 0.5) * 2.0;
    float edge = smoothstep(0.55, 1.0, max(d.x, d.y));
    c = mix(c, float3(0.9, 0.04, 0.04), edge * u.damageFlash * 0.85);

    return float4(c, 1.0);
}
