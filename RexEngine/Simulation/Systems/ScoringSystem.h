#pragma once

#include "Simulation/World.h"

void ScoringSystem_update(World& world, float gameDt);

// Arcade letter grade for the end-of-act grade screen. Accuracy carries the
// grade; the S tier additionally demands real interrupt play (denying dino
// attacks), so it can't be reached by slow-firing at stationary targets.
//   S: accuracy >= 80% and 3+ interrupt successes
//   A: accuracy >= 65%
//   B: accuracy >= 45%
//   C: accuracy >= 25%
//   D: everything below
char ScoringSystem_letter_grade(const PlayerScoreState& score);
