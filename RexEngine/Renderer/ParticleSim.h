#pragma once
#include <stdint.h>

// CPU particle pool for hit sparks, telegraphs, and other burst effects.
// Pure C++ (no Metal, no ObjC) so BrawlerLogicTests can cover it. Particles
// are deliberately NOT ECS entities: the renderer's bone buffer is indexed by
// raw EntityID with a hard 64-slot cap, so short-lived entity churn would
// push skinned characters past their slots.
//
// The renderer drains `particles()` each frame into an instanced billboard
// draw. Updated with physical dt (bursts keep moving during hit-stop).
struct ParticleSim {
    static constexpr int kCapacity = 256;

    struct Particle {
        float x, y, z;       // world position
        float vx, vy, vz;    // velocity (units/sec)
        float life;          // seconds remaining
        float lifeMax;       // starting life (for fade)
        float size;          // world units
        float r, g, b;       // color (additive)
    };

    Particle particles[kCapacity];
    int      count = 0;

    // Radial burst at (x, y, z): `n` particles fanned across a full circle
    // with slight upward bias. Drops excess if the pool is full.
    void spawn_burst(float x, float y, float z, int n,
                     float speed, float size, float r, float g, float b,
                     uint32_t seed);

    // Advance positions, apply drag + gravity, recycle dead particles.
    void update(float dt);

    void clear() { count = 0; }
};
