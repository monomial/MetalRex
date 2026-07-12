#pragma once

class World;

// Drives the post-boss "stand your ground" arena: spawns raptor waves from
// spread lanes/depths, advances to the next wave only once the current one is
// fully cleared (arena raptors loop-attack until killed), and completes the
// level after the last wave. No-ops unless World::arena_active().
void ArenaSystem_update(World& world, float gameDt);
