#pragma once
#include "Platform/InputState.h"
#include <cstdint>

class World;

// Demo autopilot: composes one tick of player input from the live world, so
// the game can play itself.
//
// Why this exists: every "does it feel right?" question in this project —
// aim tracking, weak-point tint, the attack tell's lead time, hit flash —
// is about MOTION, and motion survives neither a headless test nor a still
// screenshot. The autopilot drives a real run through the normal input path
// so scripts/capture-clip.sh can record a watchable clip of it, and so a
// soak test can play the whole act unattended (AutopilotTests).
//
// It aims through stick input exactly like a player. It never writes
// reticle.x/y, never calls a system directly, and never reaches past the
// input struct — an autopilot that teleported the reticle would prove
// nothing about the aiming it is supposed to demonstrate.
//
// It is deliberately a competent-but-not-perfect player: it leads with the
// interrupt window (the game's actual skill expression), takes weak points
// when they are exposed, and lets shots miss when the animal moves faster
// than the reticle can follow.
struct AutopilotState {
    uint64_t tick = 0;
    // Fire is HELD while on target (ReticleSystem's cooldown sets the
    // cadence). But the title join, the play-again gate and the continue
    // prompt are all edge-gated on a release, so those states pulse instead.
    int pulsePhase = 0;
    // Which target slot the bot committed to last tick. Re-picking every
    // tick made it jitter between two equally-close raptors and hit neither;
    // it holds a target until that target dies or its window closes.
    int committedTarget = -1;
};

// Pure given (world, state): the same world and state always produce the
// same input, which is what lets the soak test and the recorded clip be
// reproducible.
InputState AutopilotSystem_input(const World& world, AutopilotState& state, int playerIndex);
