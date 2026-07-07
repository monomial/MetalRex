#include "ParticleSim.h"
#include <math.h>

// Local xorshift so bursts are deterministic per seed and the sim never
// touches global rand() state.
static inline uint32_t xorshift(uint32_t& s) {
    s ^= s << 13; s ^= s >> 17; s ^= s << 5;
    return s;
}
static inline float frand01(uint32_t& s) {
    return (float)(xorshift(s) >> 8) * (1.0f / 16777216.0f);
}

static constexpr float kDrag    = 6.0f;   // exponential velocity damping /sec
static constexpr float kGravity = 600.0f; // world units/sec² pulling z down

void ParticleSim::spawn_burst(float x, float y, float z, int n,
                              float speed, float size, float r, float g, float b,
                              uint32_t seed) {
    uint32_t s = seed ? seed : 1;
    for (int i = 0; i < n; ++i) {
        if (count >= kCapacity) return; // pool full — drop the rest
        Particle& p = particles[count++];
        float ang   = frand01(s) * 2.f * (float)M_PI;
        float spd   = speed * (0.5f + frand01(s));
        p.x = x; p.y = y; p.z = z;
        p.vx = cosf(ang) * spd;
        p.vy = sinf(ang) * spd;
        p.vz = (0.3f + frand01(s) * 0.9f) * speed * 0.8f; // upward bias
        p.lifeMax = p.life = 0.25f + frand01(s) * 0.25f;
        p.size = size * (0.6f + frand01(s) * 0.8f);
        p.r = r; p.g = g; p.b = b;
    }
}

void ParticleSim::update(float dt) {
    if (dt <= 0.f) return;
    float damp = expf(-kDrag * dt);
    for (int i = 0; i < count; ) {
        Particle& p = particles[i];
        p.life -= dt;
        if (p.life <= 0.f) {
            // Swap-remove: order doesn't matter for additive billboards.
            particles[i] = particles[--count];
            continue;
        }
        p.x += p.vx * dt;
        p.y += p.vy * dt;
        p.z += p.vz * dt;
        p.vx *= damp;
        p.vy *= damp;
        p.vz  = p.vz * damp - kGravity * dt;
        if (p.z < 2.f) { p.z = 2.f; p.vz = 0.f; } // settle just above the floor
        ++i;
    }
}
