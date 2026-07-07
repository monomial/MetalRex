#include "ScreenShakeSystem.h"
#include "Simulation/World.h"
#include <math.h>
#include <stdlib.h>

// Shake state is global — one camera, one shake.
static float       s_magnitude = 0.f;
static simd_float2 s_offset    = {0, 0};

static constexpr float kDecayRate = 12.0f; // magnitude halves in ~0.06s at this rate

void ScreenShakeSystem_trigger(World& /*world*/, float magnitude) {
    if (magnitude > s_magnitude) s_magnitude = magnitude;
}

void ScreenShakeSystem_update(World& world, float physicalDt) {
    // Always consume exactly one RNG draw per tick, even when idle: shake
    // magnitude is global (one camera) while the RNG belongs to the World, so
    // conditional consumption would let one World's shake state shift another
    // seeded World's RNG stream and break deterministic replays.
    float angle = world.rand_float01() * 2.f * (float)M_PI;

    if (s_magnitude < 0.5f) {
        s_magnitude = 0.f;
        s_offset    = {0, 0};
        return;
    }

    // Exponential decay.
    s_magnitude *= expf(-kDecayRate * physicalDt);
    s_offset = { cosf(angle) * s_magnitude, sinf(angle) * s_magnitude };
}

simd_float2 ScreenShakeSystem_offset(const World& /*world*/) {
    return s_offset;
}
