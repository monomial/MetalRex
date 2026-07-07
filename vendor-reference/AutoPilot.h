#pragma once
#include "Platform/InputState.h"

class World;

// Scripted "player" for automation: walks toward the nearest living enemy and
// punches when in range. Used by the headless scenario tests and the
// --autotest visual smoke mode in place of human input. Deterministic — no
// randomness — so a seeded World replays identically.
InputState AutoPilot_input(World& world, int playerIndex);
void AutoPilot_reset();
void AutoPilot_set_dodge_enabled(bool enabled);
