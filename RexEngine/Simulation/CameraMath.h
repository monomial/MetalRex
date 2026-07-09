#pragma once

#include "RailSpline.h"
#include <cmath>
#include <simd/simd.h>

// World-space Y of the ground plane. Shared by the renderer's ground quad
// and by target/dino placement so they can't drift apart — before this,
// target height was computed relative to the rail's own Y (which varies
// 0.25-0.55 across the M2 test chart's control points) with no reference
// to the ground at all, so dinos rendered floating ~1.2-1.5 units above
// the actual ground plane.
static constexpr float kGroundWorldY = -0.45f;

static inline simd_float3 rex_to_simd(RexVec3 v) {
    return (simd_float3){v.x, v.y, v.z};
}

static inline RexVec3 rex_from_simd(simd_float3 v) {
    return {v.x, v.y, v.z};
}

static inline simd_float3 rex_safe_normalize(simd_float3 v, simd_float3 fallback) {
    float len = simd_length(v);
    return len > 0.0001f ? v / len : fallback;
}

static inline simd_float4x4 Rex_make_ortho(float left, float right, float bottom, float top, float nearZ, float farZ) {
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[0].x = 2.f / (right - left);
    m.columns[1].y = 2.f / (top - bottom);
    m.columns[2].z = 1.f / (farZ - nearZ);
    m.columns[3].x = -(right + left) / (right - left);
    m.columns[3].y = -(top + bottom) / (top - bottom);
    m.columns[3].z = -nearZ / (farZ - nearZ);
    return m;
}

static inline simd_float4x4 Rex_make_perspective(float fovyRadians, float aspect, float nearZ, float farZ) {
    float yScale = 1.f / tanf(fovyRadians * 0.5f);
    float xScale = yScale / aspect;
    float zScale = farZ / (farZ - nearZ);
    simd_float4x4 m = {};
    m.columns[0] = (simd_float4){xScale, 0.f, 0.f, 0.f};
    m.columns[1] = (simd_float4){0.f, yScale, 0.f, 0.f};
    m.columns[2] = (simd_float4){0.f, 0.f, zScale, 1.f};
    m.columns[3] = (simd_float4){0.f, 0.f, -nearZ * zScale, 0.f};
    return m;
}

static inline simd_float4x4 Rex_make_look_at(simd_float3 eye, simd_float3 target, simd_float3 upHint) {
    simd_float3 forward = rex_safe_normalize(target - eye, (simd_float3){0.f, 0.f, 1.f});
    simd_float3 right = rex_safe_normalize(simd_cross(upHint, forward), (simd_float3){1.f, 0.f, 0.f});
    simd_float3 up = rex_safe_normalize(simd_cross(forward, right), (simd_float3){0.f, 1.f, 0.f});

    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[0] = (simd_float4){right.x, up.x, forward.x, 0.f};
    m.columns[1] = (simd_float4){right.y, up.y, forward.y, 0.f};
    m.columns[2] = (simd_float4){right.z, up.z, forward.z, 0.f};
    m.columns[3] = (simd_float4){-simd_dot(right, eye), -simd_dot(up, eye), -simd_dot(forward, eye), 1.f};
    return m;
}

static inline bool Rex_project_world_to_screen(simd_float4x4 viewProjection,
                                               simd_float3 world,
                                               float *screenX,
                                               float *screenY) {
    simd_float4 clip = simd_mul(viewProjection, (simd_float4){world.x, world.y, world.z, 1.f});
    if (clip.w <= 0.0001f || !isfinite(clip.w)) return false;
    simd_float2 ndc = (simd_float2){clip.x / clip.w, clip.y / clip.w};
    if (!isfinite(ndc.x) || !isfinite(ndc.y)) return false;
    *screenX = 0.5f + ndc.x * 0.5f;
    *screenY = 0.5f + ndc.y * 0.5f;
    return true;
}
