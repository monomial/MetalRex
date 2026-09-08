#pragma once
#include "Simulation/World.h"
#include "Platform/InputState.h"
#include <functional>
#include <string>
#include <vector>

// Test-only input authoring.
//
// Before this, a scenario either needed a human to record it (REX_RECORD) or a
// bespoke per-tick set_input loop. This lets a test say what it means:
//
//     ScriptedInput script;
//     script.aimAt(0).fireWhen(Predicates::interruptWindowOpen());
//     XCTAssertTrue(script.run(world));
//
// aimAt steers through the NORMAL stick input path and never writes
// reticle.x/y directly. That is the whole point: a test that teleports the
// reticle has stopped testing hit-testing, the frustum clamp, and aim feel —
// i.e. most of what could actually break.
//
// Steps drive the world tick by tick, so predicates see live state. If the
// world has begin_recording() active, the run is captured like any other
// session and can be saved and replayed in the renderer via REX_REPLAY.
class ScriptedInput {
public:
    using Predicate = std::function<bool(const World&)>;

    explicit ScriptedInput(uint8_t player = 0) : _player(player) {}

    ScriptedInput& wait(int ticks);
    ScriptedInput& aimAt(int targetIndex, int budgetTicks = 900);
    ScriptedInput& holdUntil(Predicate p, int budgetTicks = 2000);
    ScriptedInput& fire();                                    // one shot: press 1 tick, release 2
    ScriptedInput& fireWhen(Predicate p, int budgetTicks = 2000);
    // Steers at the target EVERY tick while waiting, then fires on the tick the
    // predicate goes true. Aiming once and holding still does not work: the
    // animal keeps moving, so a reticle parked where it used to be misses.
    ScriptedInput& trackAndFireWhen(int targetIndex, Predicate p, int budgetTicks = 2000);

    // Runs every step in order. Returns false if a step ran out of budget,
    // leaving failureReason() set — a scripted scenario that silently never
    // fired would otherwise pass as a vacuous assertion.
    bool run(World &world, int maxTicks = 20000);
    const std::string& failureReason() const { return _failure; }
    int ticksRun() const { return _ticksRun; }

private:
    struct Step {
        std::function<bool(const World&, int)> done;          // (world, ticksSpentInStep)
        std::function<void(const World&, InputState&)> apply; // fill this tick's input
        int budget;
        std::string label;
    };
    std::vector<Step> _steps;
    std::string _failure;
    uint8_t _player;
    int _ticksRun = 0;
};

namespace Predicates {
// Deliberately a small, concrete set — not an expression language.
ScriptedInput::Predicate interruptWindowOpen();               // any non-boss dino, window open
ScriptedInput::Predicate interruptWindowOpenForTarget(int targetIndex); // that dino specifically
ScriptedInput::Predicate anyDinoInState(DinoBehaviorState s);
ScriptedInput::Predicate targetActive(int targetIndex);
}
