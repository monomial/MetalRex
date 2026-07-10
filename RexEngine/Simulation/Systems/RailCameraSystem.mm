#include "RailCameraSystem.h"
#include "Simulation/CameraMath.h"
#include "Simulation/ChartLoader.h"
#include "Simulation/World.h"
#include <algorithm>
#include <cmath>

static float clamp01_local(float value) {
    return std::min(1.f, std::max(0.f, value));
}

// How far behind the jeep the camera aims. Far enough that a dino at attack
// range sits between the camera and the aim point (well framed), close
// enough that the view stays tight on the pursuers.
static constexpr float kLookBackDistance = 4.0f;

static void update_camera_basis(RailCameraState& camera, const LevelChart& chart) {
    float railLength = chart.rail.total_length();
    // Loop back to the start rather than clamping at the end: clamping left
    // the camera permanently stuck once it reached the rail's length (~30s
    // at the default speed against the M2 test chart) — which is also what
    // caused a real hang in update_targets below, since target respawn logic
    // assumes the camera keeps advancing and can never "catch up" once it's
    // frozen at the far end. This is a test-scene loop; a real level (M5+)
    // will end the act instead of looping.
    if (railLength > 0.0001f) {
        camera.distance = fmodf(camera.distance, railLength);
        if (camera.distance < 0.f) camera.distance += railLength;
    } else {
        camera.distance = 0.f;
    }
    camera.rawT = chart.rail.raw_t_at_distance(camera.distance);

    RexVec3 position = chart.rail.position_at_distance(camera.distance);
    // Jeep scenario: the camera rides the rail forward but FACES BACKWARD —
    // the player is in the back of the jeep shooting at dinos chasing it.
    // Aim at a point on the rail behind the jeep (clamped at the rail start,
    // briefly relevant right after the test-scene loop wraps). The chart's
    // authored lookAtBeats are unused in this scenario; they stay in the
    // chart format for future cinematic camera sweeps.
    float lookBack = camera.distance - kLookBackDistance;
    if (lookBack < 0.f) lookBack = 0.f;
    RexVec3 lookAt = chart.rail.position_at_distance(lookBack);
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
    // Start partway down the rail so there's road BEHIND the jeep for
    // pursuers to spawn and chase on (the rail has no geometry before
    // distance 0).
    camera.distance = 8.f;
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
        // Popup flicker applies only to non-dino box targets (none are
        // spawned by default currently, but the mechanism stays available
        // for future set-piece targets); every dino anchor sets moving=true
        // and stays active below instead.
        if (!target.moving) {
            float phase = fmodf(camera.elapsed + target.timerOffset, 3.0f);
            target.active = phase < 2.25f;
        }
        if (target.moving) {
            // Gentle side-to-side weave while chasing. The old ±0.9 at
            // 1.45 rad/s read as the dino floating sideways in big arcs
            // relative to everything else on screen.
            target.lateralOffset = sinf(camera.elapsed * 0.8f) * 0.35f;
            // Small run-cycle bob around ground level.
            target.verticalOffset = sinf(camera.elapsed * 2.1f) * 0.04f;
            target.active = true;
        }

        // Targets live BEHIND the jeep (the camera faces backward at
        // pursuers). gap = how far behind the camera this target is.
        // - Fell too far back (the jeep outran it): recycle it closer, as a
        //   fresh pursuer catching up.
        // - Reached the jeep (or started out ahead of it, like the initial
        //   box-target layout): pin it just behind — nothing may pass the
        //   jeep. Dino movement itself stops at attackRange (> 1), so this
        //   clamp is a safety net, not the gameplay path.
        // No loop, so no hang path: one assignment always lands in range.
        float gap = camera.distance - target.railDistance;
        if (gap > 10.f) {
            // Recycle deep, not close: a fresh pursuer should be seen
            // running up from the distance, not popping in at arm's length.
            gap = 5.f + (float)i * 0.8f;
            target.railDistance = std::max(0.f, camera.distance - gap);
            target.wasHit = false;
            target.lastHitWasWeakPoint = false;
            target.lastHitByPlayer = UINT8_MAX;
        } else if (gap < 1.0f) {
            target.railDistance = std::max(0.f, camera.distance - 1.0f);
        }

        RexVec3 center = chart.rail.position_at_distance(target.railDistance);
        RexVec3 tangent = chart.rail.tangent_at_distance(target.railDistance);
        simd_float3 forward = rex_safe_normalize(rex_to_simd(tangent), (simd_float3){0.f, 0.f, 1.f});
        simd_float3 right = rex_safe_normalize(simd_cross((simd_float3){0.f, 1.f, 0.f}, forward),
                                               (simd_float3){1.f, 0.f, 0.f});
        // Y is anchored to the ground plane, NOT the rail's own Y (which
        // varies with the camera's height along the chart) — target.worldY
        // is consumed as "box center height" by both the box-target renderer
        // and (via CharacterLoader's meshYMin/halfHeight alignment) the
        // skinned-dino renderer, so ground + halfHeight puts feet exactly on
        // the ground when verticalOffset is 0. Previously this used
        // center.y (the rail's height, 0.25-0.55 across the M2 test chart)
        // with a large verticalOffset (0.35-0.67) on top, which floated
        // targets roughly 1.2-1.5 world units above the actual ground.
        simd_float3 worldCenter = rex_to_simd(center)
                                + right * target.lateralOffset;
        worldCenter.y = kGroundWorldY + target.halfHeight + target.verticalOffset;
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
            target.weakPointHalfW = 0.f;
            target.weakPointOffsetY = 0.f;
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
        target.weakPointHalfW = target.screenHalfW * 0.55f;
        target.weakPointOffsetY = target.screenHalfH * 0.65f;
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
