#include "ScreenShakeSystem.h"
#include "Simulation/World.h"
#include <math.h>
#include <stdlib.h>

static constexpr float kDecayRate = 12.0f; // magnitude halves in ~0.06s at this rate
// The offset translates the camera in WORLD units (see _worldViewProjection
// in RexRenderer), and this game's world is small — the road is 3.4 units
// wide, targets sit a few units from the camera — so a "big" shake is on the
// order of a few tenths of a unit, not the ~0.5+ this cutoff might suggest
// at a glance. It only needs to be small enough that a shake decays fully
// rather than leaving an imperceptible residual offset forever.
static constexpr float kMinVisibleMagnitude = 0.01f;

void ScreenShakeSystem_trigger(World& world, float magnitude) {
    if (magnitude > world._shakeMagnitude) world._shakeMagnitude = magnitude;
}

void ScreenShakeSystem_update(World& world, float gameDt) {
    // Always consume exactly one RNG draw per tick, even when idle: conditional
    // consumption would let shake state shift the seeded simulation RNG stream.
    float angle = world.rand_float01() * 2.f * (float)M_PI;

    if (world._shakeMagnitude < kMinVisibleMagnitude) {
        world._shakeMagnitude = 0.f;
        world._shakeOffset    = {0, 0};
        return;
    }

    // Exponential decay.
    world._shakeMagnitude *= expf(-kDecayRate * gameDt);
    world._shakeOffset = { cosf(angle) * world._shakeMagnitude, sinf(angle) * world._shakeMagnitude };
}

simd_float2 ScreenShakeSystem_offset(const World& world) {
    return world._shakeOffset;
}
