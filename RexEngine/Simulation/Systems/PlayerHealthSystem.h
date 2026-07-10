#pragma once
#include "Simulation/World.h"

// Ticks each active player's health timers (hit flash, post-hit
// invulnerability) and, while a player is sitting out, watches that player's
// own fire button to "insert a coin" and continue. Damage itself is applied by
// DinoBehaviorSystem via World::damage_player when a dino's attack lands
// unopposed.
void PlayerHealthSystem_update(World& world, float gameDt);
