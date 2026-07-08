#pragma once
class World;

struct ReticleTuning {
    float stickSensitivityH = 0.72f;
    float stickSensitivityV = 0.58f;
    float gyroSensitivityH = 0.34f;
    float gyroSensitivityV = 0.28f;
    float stillnessThreshold = 0.0014f;
    float stillnessSmoothingAlpha = 0.18f;
    float fallbackFrictionScale = 0.42f;
    float fallbackMagnetRadius = 0.06f;
    float fallbackMagnetStrength = 0.16f;
};

ReticleTuning ReticleSystem_tuning();
void ReticleSystem_set_tuning(ReticleTuning tuning);
void ReticleSystem_adjust_tuning(float stickDelta, float gyroDelta, float smoothingDelta);
void ReticleSystem_adjust_fallback_tuning(float frictionDelta, float radiusDelta, float strengthDelta);

void ReticleSystem_update(World& world, float gameDt);
