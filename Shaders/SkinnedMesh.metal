#include <metal_stdlib>
using namespace metal;

constant int kMaxBones = 64;

struct SkinnedVertex {
    float3  position    [[attribute(0)]];
    float3  normal      [[attribute(1)]];
    float2  texcoord    [[attribute(2)]];
    float4  color       [[attribute(3)]];
    ushort4 jointIdx    [[attribute(4)]];
    float4  jointWeight [[attribute(5)]];
};

struct SkinnedOut {
    float4 position [[position]];
    float3 worldNormal;
    float2 texcoord;
    float4 vertexColor;
    float4 tint;         // faction color passed through
    float  tintStrength; // how strongly tint blends over the texture
};

struct SkinnedUniforms {
    float4x4 mvp;
    float4x4 modelRotation; // rotation-only (no scale/translation) — applied
                            // to normals so lighting matches the model's
                            // actual orientation. Bone matrices already
                            // handle per-joint rotation; this is the
                            // separate whole-model yaw (e.g. facing the
                            // camera) that mvp applies to position but which
                            // was never applied to normals at all before —
                            // harmless while every model transform was
                            // scale-only (uniform scale doesn't change
                            // normal direction), not harmless once a model
                            // can also rotate.
    float4   color;        // faction tint
    float    tintStrength; // 0 = pure texture, 1 = pure faction color
};

vertex SkinnedOut skinned_vertex_main(
    SkinnedVertex in              [[stage_in]],
    constant float4x4 *bones     [[buffer(1)]],
    constant SkinnedUniforms &u  [[buffer(2)]])
{
    float4 pos = float4(in.position, 1.0);
    float4 nrm = float4(in.normal,   0.0);

    float4 skPos = float4(0.0);
    float4 skNrm = float4(0.0);

    for (int i = 0; i < 4; i++) {
        float w = in.jointWeight[i];
        if (w > 0.001) {
            uint j = in.jointIdx[i];
            skPos += w * (bones[j] * pos);
            skNrm += w * (bones[j] * nrm);
        }
    }

    SkinnedOut out;
    out.position     = u.mvp * skPos;
    out.worldNormal  = normalize((u.modelRotation * skNrm).xyz);
    out.texcoord     = in.texcoord;
    out.vertexColor  = in.color;
    out.tint         = u.color;
    out.tintStrength = u.tintStrength;
    return out;
}

fragment float4 skinned_fragment_main(
    SkinnedOut in                  [[stage_in]],
    texture2d<float> diffuseTex   [[texture(0)]],
    sampler           texSampler  [[sampler(0)]])
{
    // Screen-door dissolve for corpse fade-out: tint.a carries deathFade
    // (1 = solid). Discarding by a per-pixel hash needs no blending and no
    // depth sorting.
    if (in.tint.a < 1.0) {
        float h = fract(sin(dot(in.position.xy, float2(12.9898, 78.233))) * 43758.5453);
        if (h > in.tint.a) discard_fragment();
    }

    // Sample character skin texture; fall back to white if texture is missing/1x1.
    float4 texColor = diffuseTex.sample(texSampler, in.texcoord);

    // Faction tint blend — subtle for players (texture dominates), heavy for
    // enemies so they read as distinct while sharing the player mesh.
    float3 base = mix(texColor.rgb * in.vertexColor.rgb, in.tint.rgb, in.tintStrength);

    // Diffuse lighting with a fixed directional light.
    float3 lightDir = normalize(float3(0.5, 0.8, 1.0));
    float  diffuse  = saturate(dot(normalize(in.worldNormal), lightDir));
    float  shade    = 0.3 + 0.7 * diffuse;

    return float4(base * shade, 1.0);
}
