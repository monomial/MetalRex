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
