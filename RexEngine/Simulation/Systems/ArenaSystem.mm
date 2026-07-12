#include "ArenaSystem.h"
#include "Simulation/World.h"
#include "Simulation/Systems/DinoBehaviorSystem.h"
#include <algorithm>

// Escalating wave layouts (lane offsets across the road, left to right). Wave i
// uses layout min(i, count-1), so a fight longer than the table reuses the
// widest/densest layout. spawnGap is the base depth behind the stopped jeep;
// each raptor in a wave is pushed slightly deeper and staggered so they arrive
// from a spread of angles rather than a wall. Chart-authored layouts can
// replace this table later.
struct ArenaWaveLayout {
    int count;
    float lanes[6];
    float spawnGap;
    float holdSeconds;
    float attackStagger;
};

static const ArenaWaveLayout kLayouts[] = {
    {2, {-1.8f,  1.8f,  0.f,  0.f,  0.f,  0.f}, 9.0f, 1.6f, 0.40f},
    {3, {-2.6f,  0.0f,  2.6f, 0.f,  0.f,  0.f}, 8.0f, 1.4f, 0.35f},
    {4, {-2.2f, -0.8f,  0.8f, 2.2f, 0.f,  0.f}, 7.5f, 1.2f, 0.30f},
    {5, {-2.6f, -1.3f,  0.0f, 1.3f, 2.6f, 0.f}, 7.0f, 1.1f, 0.28f},
};
static const int kLayoutCount = (int)(sizeof(kLayouts) / sizeof(kLayouts[0]));

static int count_active_arena_raptors(World& world) {
    int n = 0;
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.has_component<DinoBehaviorComponent>(id)) continue;
        const DinoBehaviorComponent& dino = world.get_component<DinoBehaviorComponent>(id);
        if (dino.arena && dino.activeInEncounter) ++n;
    }
    return n;
}

static void spawn_wave(World& world, int waveIndex) {
    const ArenaWaveLayout& layout = kLayouts[std::min(waveIndex, kLayoutCount - 1)];
    for (int i = 0; i < layout.count; ++i) {
        DinoBehaviorSystem_spawn_arena_raptor(world, (uint32_t)(waveIndex + 1),
                                              layout.lanes[i],
                                              layout.spawnGap + (float)i * 0.6f,
                                              layout.holdSeconds,
                                              layout.attackStagger * (float)i);
    }
}

void ArenaSystem_update(World& world, float gameDt) {
    ArenaState& arena = world.arena_mutable();
    if (!arena.active) return;
    int totalWaves = world.chart().arenaWaveCount;

    switch (arena.phase) {
        case ArenaState::WaitingToSpawn: {
            arena.timer = std::max(0.f, arena.timer - gameDt);
            if (arena.timer > 0.f) return;
            if (arena.waveIndex + 1 >= totalWaves) {
                // Survived every wave — the holdout is won.
                arena.active = false;
                world.complete_level();
                return;
            }
            arena.waveIndex += 1;
            spawn_wave(world, arena.waveIndex);
            arena.phase = ArenaState::InProgress;
            return;
        }
        case ArenaState::InProgress: {
            // A wave clears only when every raptor in it is dead (they loop
            // attacking until killed, so this can't be waited out).
            if (count_active_arena_raptors(world) == 0) {
                arena.phase = ArenaState::WaitingToSpawn;
                arena.timer = kArenaInterWaveDelay;
            }
            return;
        }
    }
}
