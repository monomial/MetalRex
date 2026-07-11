#include "ReticleSystem.h"
#include "Simulation/World.h"
#include "Simulation/BossMajorAttackPoints.h"
#include <algorithm>
#include <math.h>

static ReticleTuning s_tuning;

static float clamp01(float value) {
    return std::min(1.f, std::max(0.f, value));
}

static float clamp_range(float value, float lo, float hi) {
    return std::min(hi, std::max(lo, value));
}

static float smooth_toward(float previous, float current, float alpha) {
    return previous + (current - previous) * alpha;
}

static bool point_inside(const ReticleComponent& reticle, const TargetComponent& target) {
    if (!target.active) return false;
    return fabsf(reticle.x - target.screenX) <= target.screenHalfW
        && fabsf(reticle.y - target.screenY) <= target.screenHalfH;
}

static bool point_inside_weak_point(const ReticleComponent& reticle, const TargetComponent& target) {
    if (!target.active || target.weakPointHalfW <= 0.f || target.screenHalfH <= 0.f) return false;
    float weakCenterY = target.screenY + target.weakPointOffsetY;
    float weakHalfH = target.screenHalfH * 0.35f;
    return fabsf(reticle.x - target.screenX) <= target.weakPointHalfW
        && fabsf(reticle.y - weakCenterY) <= weakHalfH;
}

// A boss major-attack point is a flat circle in viewport space, unrelated to
// the live 3D rail-camera projection kM1MaxTargets targets use — the popup
// is a static 2D portrait, not a proxy for a world position. See
// BossMajorAttackPoints.h for the (u,v)->(x,y) conversion.
static bool point_inside_major_attack_point(const ReticleComponent& reticle,
                                            const BossMajorAttackPoint& point) {
    float px, py;
    BossMajorAttackPoint_toViewport(point, &px, &py);
    float dx = reticle.x - px;
    float dy = reticle.y - py;
    return (dx * dx + dy * dy) <= (point.hitRadius * point.hitRadius);
}

ReticleTuning ReticleSystem_tuning() {
    return s_tuning;
}

void ReticleSystem_set_tuning(ReticleTuning tuning) {
    tuning.stickSensitivityH = clamp_range(tuning.stickSensitivityH, 0.05f, 2.0f);
    tuning.stickSensitivityV = clamp_range(tuning.stickSensitivityV, 0.05f, 2.0f);
    tuning.gyroSensitivityH = clamp_range(tuning.gyroSensitivityH, 0.02f, 1.4f);
    tuning.gyroSensitivityV = clamp_range(tuning.gyroSensitivityV, 0.02f, 1.4f);
    tuning.stillnessThreshold = clamp_range(tuning.stillnessThreshold, 0.0001f, 0.04f);
    tuning.stillnessSmoothingAlpha = clamp_range(tuning.stillnessSmoothingAlpha, 0.02f, 1.0f);
    tuning.fallbackFrictionScale = clamp_range(tuning.fallbackFrictionScale, 0.1f, 1.0f);
    tuning.fallbackMagnetRadius = clamp_range(tuning.fallbackMagnetRadius, 0.01f, 0.3f);
    tuning.fallbackMagnetStrength = clamp_range(tuning.fallbackMagnetStrength, 0.0f, 1.0f);
    s_tuning = tuning;
}

void ReticleSystem_adjust_tuning(float stickDelta, float gyroDelta, float smoothingDelta) {
    ReticleTuning tuning = s_tuning;
    tuning.stickSensitivityH += stickDelta;
    tuning.stickSensitivityV += stickDelta;
    tuning.gyroSensitivityH += gyroDelta;
    tuning.gyroSensitivityV += gyroDelta;
    tuning.stillnessSmoothingAlpha += smoothingDelta;
    ReticleSystem_set_tuning(tuning);
}

void ReticleSystem_adjust_fallback_tuning(float frictionDelta, float radiusDelta, float strengthDelta) {
    ReticleTuning tuning = s_tuning;
    tuning.fallbackFrictionScale += frictionDelta;
    tuning.fallbackMagnetRadius += radiusDelta;
    tuning.fallbackMagnetStrength += strengthDelta;
    ReticleSystem_set_tuning(tuning);
}

void ReticleSystem_update(World& world, float gameDt) {
    if (gameDt == 0.f) return;

    for (int player = 0; player < kRexMaxPlayers; ++player) {
        ReticleComponent& reticle = world.reticle(player);
        reticle.stickSensitivityH = s_tuning.stickSensitivityH;
        reticle.stickSensitivityV = s_tuning.stickSensitivityV;
        reticle.gyroSensitivityH = s_tuning.gyroSensitivityH;
        reticle.gyroSensitivityV = s_tuning.gyroSensitivityV;
        reticle.smoothingAlpha = s_tuning.stillnessSmoothingAlpha;
        reticle.stillnessThreshold = s_tuning.stillnessThreshold;
        if (!reticle.active) continue;
        if (world.player_health(player).sittingOut) {
            reticle.overTarget = false;
            continue;
        }

        InputState input = world.current_input(player);
        bool hasGyro = fabsf(input.gyroDeltaX) > 0.000001f || fabsf(input.gyroDeltaY) > 0.000001f;
        reticle.gyroAvailable = hasGyro || reticle.gyroAvailable;
        reticle.stickOnlyAssist = !reticle.gyroAvailable;

        if (input.recenter) {
            reticle.x = 0.5f;
            reticle.y = 0.5f;
            reticle.smoothedGyroX = 0.f;
            reticle.smoothedGyroY = 0.f;
            reticle.gyroDriftX = 0.f;
            reticle.gyroDriftY = 0.f;
            continue;
        }

        reticle.overTarget = false;
        TargetComponent* nearest = nullptr;
        float nearestDistSq = s_tuning.fallbackMagnetRadius * s_tuning.fallbackMagnetRadius;
        for (int i = 0; i < kM1MaxTargets; ++i) {
            TargetComponent& target = world.target(i);
            if (point_inside(reticle, target)) reticle.overTarget = true;
            if (!target.active) continue;
            float dx = target.screenX - reticle.x;
            float dy = target.screenY - reticle.y;
            float distSq = dx * dx + dy * dy;
            if (distSq < nearestDistSq) {
                nearestDistSq = distSq;
                nearest = &target;
            }
        }

        float stickScale = (reticle.stickOnlyAssist && reticle.overTarget)
                         ? s_tuning.fallbackFrictionScale : 1.f;
        float dx = input.stickX * s_tuning.stickSensitivityH * gameDt * stickScale;
        float dy = input.stickY * s_tuning.stickSensitivityV * gameDt * stickScale;

        float rawGyroX = input.gyroDeltaX;
        float rawGyroY = input.gyroDeltaY;
        float gyroMag = sqrtf(rawGyroX * rawGyroX + rawGyroY * rawGyroY);
        float gyroX = rawGyroX;
        float gyroY = rawGyroY;
        if (gyroMag < s_tuning.stillnessThreshold) {
            gyroX = smooth_toward(reticle.smoothedGyroX, rawGyroX, s_tuning.stillnessSmoothingAlpha);
            gyroY = smooth_toward(reticle.smoothedGyroY, rawGyroY, s_tuning.stillnessSmoothingAlpha);
        }
        reticle.smoothedGyroX = gyroX;
        reticle.smoothedGyroY = gyroY;
        reticle.gyroDriftX += gyroX;
        reticle.gyroDriftY += gyroY;

        dx += gyroX * s_tuning.gyroSensitivityH;
        dy += gyroY * s_tuning.gyroSensitivityV;

        if (reticle.stickOnlyAssist && nearest) {
            float dist = sqrtf(nearestDistSq);
            if (dist > 0.0001f) {
                float pullDirX = (nearest->screenX - reticle.x) / dist;
                float pullDirY = (nearest->screenY - reticle.y) / dist;
                // Never fight a deliberate escape: this is supposed to be friction
                // (helps you stay put) plus a gentle assist (helps you settle in),
                // not a tug-of-war. If the player's own input already has a
                // component pointing away from the target, skip the pull this
                // tick rather than opposing it — the previous unconditional pull
                // (strongest exactly when closest, per the (1 - dist/radius)
                // term) could match or exceed the player's escape velocity and
                // read as a soft snap-lock.
                float towardDot = dx * pullDirX + dy * pullDirY;
                if (towardDot >= 0.f) {
                    float pull = (1.f - dist / s_tuning.fallbackMagnetRadius)
                               * s_tuning.fallbackMagnetStrength * gameDt;
                    dx += pullDirX * pull;
                    dy += pullDirY * pull;
                }
            }
        }

        reticle.x = clamp01(reticle.x + dx);
        reticle.y = clamp01(reticle.y + dy);

        if (reticle.fireFlashTime > 0.f) {
            reticle.fireFlashTime = std::max(0.f, reticle.fireFlashTime - gameDt);
        }
        if (reticle.fireCooldown > 0.f) {
            reticle.fireCooldown -= gameDt;
        }
        // Cooldown-gated: a held trigger fires at kFireCooldown cadence
        // (~5.5 shots/s), not once per 120Hz tick — without the gate,
        // holding fire dealt 120 hits/second and melted anything instantly.
        if (input.fire && reticle.fireCooldown <= 0.f) {
            reticle.fireCooldown = kFireCooldown;
            reticle.fireFlashTime = kFireFlashDuration;
            reticle.shotCount += 1;
            world.audio_cues().shotsFired += 1;
            if (world.major_attack_active()) {
                // A flat 2D popup, not the live 3D scene — its 4 points get
                // their own hit-test entirely separate from the kM1MaxTargets
                // loop below (that loop stays untouched, but it's simply
                // never reached this branch, so the boss's own — now stale,
                // slow-motion — TargetComponent box can't be hit by mistake
                // while the popup covers it).
                BossMajorAttackState& attack = world.major_attack_mutable();
                const BossMajorAttackPoint* points = BossMajorAttackPoints_for(attack.species);
                for (int i = 0; i < kBossMajorAttackPointCount; ++i) {
                    if (attack.hitMask & (1 << i)) continue; // already claimed
                    if (!point_inside_major_attack_point(reticle, points[i])) continue;
                    attack.hitMask |= (uint8_t)(1 << i);
                    attack.hitCount += 1;
                    float px, py;
                    BossMajorAttackPoint_toViewport(points[i], &px, &py);
                    world.events().push_dino_score((uint8_t)player, DinoScoreEvent::MajorAttackPointHit,
                                                   attack.species, px, py);
                    break; // one shot claims at most one point
                }
            } else {
                // One bullet hits ONE dino: of every target whose screen box
                // contains the reticle, only the front-most (nearest the
                // camera, i.e. largest railDistance — pursuers trail behind
                // the jeep) takes the hit. Marking every containing box, as
                // this used to, meant a raptor standing inside the T-Rex's
                // much larger screen box shielded nothing — one trigger pull
                // silently damaged both.
                int hitIndex = -1;
                bool hitWasWeakPoint = false;
                float hitRailDistance = 0.f;
                for (int i = 0; i < kM1MaxTargets; ++i) {
                    TargetComponent& target = world.target(i);
                    bool weakPointHit = point_inside_weak_point(reticle, target);
                    if (!weakPointHit && !point_inside(reticle, target)) continue;
                    if (hitIndex < 0 || target.railDistance > hitRailDistance) {
                        hitIndex = i;
                        hitRailDistance = target.railDistance;
                        hitWasWeakPoint = weakPointHit;
                    }
                }
                if (hitIndex >= 0) {
                    TargetComponent& target = world.target(hitIndex);
                    target.wasHit = true;
                    target.lastHitWasWeakPoint = hitWasWeakPoint;
                    target.lastHitByPlayer = (uint8_t)player;
                }
            }
        }
    }
}
