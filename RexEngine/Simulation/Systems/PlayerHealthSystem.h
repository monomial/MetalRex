#pragma once
#include "Simulation/World.h"

// Ticks the shared jeep/player health's timers (hit flash, post-hit
// invulnerability) and, while PlayerHealthState::gameOver is set, watches for
// any active player pressing fire to "insert a coin" and continue. Damage
// itself is applied by DinoBehaviorSystem via World::damage_player when a
// dino's attack lands unopposed.
void PlayerHealthSystem_update(World& world, float gameDt);
