#include "RailCameraSystem.h"
#include "Simulation/CameraMath.h"
#include "Simulation/ChartLoader.h"
#include "Simulation/World.h"
#include <algorithm>
#include <cmath>

static float clamp01_local(float value) {
    return std::min(1.f, std::max(0.f, value));
}

static RexVec3 interpolate_look_at(const LevelChart& chart, float distance) {
    const std::vector<LookAtBeat>& beats = chart.lookAtBeats;
    if (beats.empty()) return chart.rail.position_at_distance(distance + 2.f);
    if (distance <= beats.front().distance) return beats.front().target;
    if (distance >= beats.back().distance) return beats.back().target;

    for (size_t i = 1; i < beats.size(); ++i) {
        if (distance <= beats[i].distance) {
            const LookAtBeat& a = beats[i - 1];
            const LookAtBeat& b = beats[i];
            float span = b.distance - a.distance;
            float alpha = span > 0.0001f ? (distance - a.distance) / span : 1.f;
            return RexVec3_add(RexVec3_scale(a.target, 1.f - alpha), RexVec3_scale(b.target, alpha));
        }
    }
    return beats.back().target;
}

static void update_camera_basis(RailCameraState& camera, const LevelChart& chart) {
    float railLength = chart.rail.total_length();
    camera.distance = std::clamp(camera.distance, 0.f, railLength);
    camera.rawT = chart.rail.raw_t_at_distance(camera.distance);

    RexVec3 position = chart.rail.position_at_distance(camera.distance);
    RexVec3 lookAt = interpolate_look_at(chart, camera.distance);
    simd_float3 eye = rex_to_simd(position);
    simd_float3 target = rex_to_simd(lookAt);
    simd_float3 forward = rex_safe_normalize(target - eye, rex_to_simd(chart.rail.tangent_at_distance(camera.distance)));
    simd_float3 right = rex_safe_normalize(simd_cross((simd_float3){0.f, 1.f, 0.f}, forward),
                                           (simd_float3){1.f, 0.f, 0.f});
    simd_float3 up = rex_safe_normalize(simd_cross(forward, right), (simd_float3){0.f, 1.f, 0.f});

    camera.positionX = position.x;
    camera.positionY = position.y;
    camera.positionZ = position.z;
    camera.lookAtX = lookAt.x;
    camera.lookAtY = lookAt.y;
    camera.lookAtZ = lookAt.z;
    camera.rightX = right.x;
    camera.rightY = right.y;
    camera.rightZ = right.z;
    camera.upX = up.x;
    camera.upY = up.y;
    camera.upZ = up.z;
}

void RailCameraSystem_reset(RailCameraState& camera, const LevelChart& chart) {
    camera = {};
    camera.speed = 1.2f;
    camera.fovYRadians = 1.04719758f;
    camera.aspect = 16.f / 9.f;
    camera.nearZ = 0.1f;
    camera.farZ = 120.f;
    update_camera_basis(camera, chart);
}

static simd_float4x4 view_projection_for_camera(const RailCameraState& camera) {
    simd_float3 eye = (simd_float3){camera.positionX, camera.positionY, camera.positionZ};
    simd_float3 lookAt = (simd_float3){camera.lookAtX, camera.lookAtY, camera.lookAtZ};
    simd_float4x4 view = Rex_make_look_at(eye, lookAt, (simd_float3){0.f, 1.f, 0.f});
    simd_float4x4 projection = Rex_make_perspective(camera.fovYRadians, camera.aspect, camera.nearZ, camera.farZ);
    return simd_mul(projection, view);
}

static void update_targets(World& world, float gameDt) {
    const LevelChart& chart = world.chart();
    const RailCameraState& camera = world.rail_camera();
    simd_float4x4 viewProjection = view_projection_for_camera(camera);
    simd_float3 cameraRight = (simd_float3){camera.rightX, camera.rightY, camera.rightZ};
    simd_float3 cameraUp = (simd_float3){camera.upX, camera.upY, camera.upZ};

    for (int i = 0; i < kM1MaxTargets; ++i) {
        TargetComponent& target = world.target(i);
        if (i == 0 || i == 1 || i == 2 || i == 4 || i == 5) {
            float phase = fmodf(camera.elapsed + target.timerOffset, 3.0f);
            target.active = phase < 2.25f;
        }
        if (target.moving) {
            target.lateralOffset = sinf(camera.elapsed * 1.45f) * 0.9f;
            target.verticalOffset = 0.55f + sinf(camera.elapsed * 2.1f) * 0.12f;
            target.active = true;
        }

        while (target.railDistance < camera.distance + 2.2f) {
            target.railDistance += 6.0f;
            if (target.railDistance > chart.rail.total_length() - 1.0f) {
                target.railDistance = 2.5f + (float)i * 1.4f;
            }
            target.wasHit = false;
        }

        RexVec3 center = chart.rail.position_at_distance(target.railDistance);
        RexVec3 tangent = chart.rail.tangent_at_distance(target.railDistance);
        simd_float3 forward = rex_safe_normalize(rex_to_simd(tangent), (simd_float3){0.f, 0.f, 1.f});
        simd_float3 right = rex_safe_normalize(simd_cross((simd_float3){0.f, 1.f, 0.f}, forward),
                                               (simd_float3){1.f, 0.f, 0.f});
        simd_float3 worldCenter = rex_to_simd(center)
                                + right * target.lateralOffset
                                + (simd_float3){0.f, target.verticalOffset, 0.f};
        target.worldX = worldCenter.x;
        target.worldY = worldCenter.y;
        target.worldZ = worldCenter.z;

        float xs[4];
        float ys[4];
        simd_float3 corners[4] = {
            worldCenter - cameraRight * target.halfWidth - cameraUp * target.halfHeight,
            worldCenter + cameraRight * target.halfWidth - cameraUp * target.halfHeight,
            worldCenter - cameraRight * target.halfWidth + cameraUp * target.halfHeight,
            worldCenter + cameraRight * target.halfWidth + cameraUp * target.halfHeight,
        };
        bool visible = true;
        for (int c = 0; c < 4; ++c) {
            if (!Rex_project_world_to_screen(viewProjection, corners[c], &xs[c], &ys[c])) {
                visible = false;
                break;
            }
        }
        if (!visible) {
            target.screenHalfW = 0.f;
            target.screenHalfH = 0.f;
            continue;
        }

        float minX = *std::min_element(xs, xs + 4);
        float maxX = *std::max_element(xs, xs + 4);
        float minY = *std::min_element(ys, ys + 4);
        float maxY = *std::max_element(ys, ys + 4);
        target.screenX = clamp01_local((minX + maxX) * 0.5f);
        target.screenY = clamp01_local((minY + maxY) * 0.5f);
        target.screenHalfW = std::clamp((maxX - minX) * 0.5f, 0.015f, 0.18f);
        target.screenHalfH = std::clamp((maxY - minY) * 0.5f, 0.02f, 0.20f);
    }

    (void)gameDt;
}

void RailCameraSystem_update(World& world, float gameDt) {
    if (gameDt == 0.f) return;
    RailCameraState& camera = world.rail_camera();
    camera.elapsed += gameDt;
    camera.distance += camera.speed * gameDt;
    update_camera_basis(camera, world.chart());
    update_targets(world, gameDt);
}
