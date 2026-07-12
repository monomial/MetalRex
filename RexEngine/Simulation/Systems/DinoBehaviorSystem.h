#pragma once
#include "Simulation/World.h"

void DinoBehaviorSystem_update(World& world, float gameDt);

// Claims a dormant raptor from the pool and activates it as an arena-defense
// pursuer at the given lane/depth (see ArenaSystem). Returns true if a slot
// was free. laneOffset is lateral across the road; spawnGap is how far behind
// the (stopped) jeep it starts.
bool DinoBehaviorSystem_spawn_arena_raptor(World& world, uint32_t waveId,
                                           float laneOffset, float spawnGap,
                                           float holdSeconds, float attackDelay);

