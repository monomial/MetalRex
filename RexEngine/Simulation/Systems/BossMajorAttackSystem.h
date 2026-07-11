#pragma once

#include "Simulation/World.h"

// Owns the boss major-attack QTE's real-time countdown and resolution
// (Perfect vs. graduated failure damage). Runs at full, unscaled gameDt even
// while camera/boss/animation are in slow motion (see World::tick) — the
// countdown must mean "a few seconds," and resolving must not itself be
// slowed. Arming happens in DinoBehaviorSystem at rage-phase escalation
// (World::begin_boss_major_attack); hit registration happens in
// ReticleSystem (writes into World::major_attack_mutable().hitMask).
void BossMajorAttackSystem_update(World& world, float gameDt);
