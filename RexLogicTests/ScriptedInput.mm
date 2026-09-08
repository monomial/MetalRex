#import "ScriptedInput.h"
#include <algorithm>
#include <cmath>

static constexpr float kScriptDt = 1.f / 120.f;

ScriptedInput& ScriptedInput::wait(int ticks) {
    _steps.push_back({[ticks](const World&, int spent) { return spent >= ticks; },
                      [](const World&, InputState&) {},
                      ticks + 1, "wait"});
    return *this;
}

ScriptedInput& ScriptedInput::aimAt(int targetIndex, int budgetTicks) {
    // Full deflection until close, easing near the target so the reticle
    // settles instead of oscillating around it at stick speed.
    auto steer = [targetIndex](const World& w, InputState& in) {
        const TargetComponent& t = w.target(targetIndex);
        const ReticleComponent& r = w.reticle(0);
        float dx = t.screenX - r.x, dy = t.screenY - r.y;
        in.stickX = std::clamp(dx * 40.f, -1.f, 1.f);
        in.stickY = std::clamp(dy * 40.f, -1.f, 1.f);
    };
    auto onTarget = [targetIndex](const World& w, int) {
        const TargetComponent& t = w.target(targetIndex);
        if (!t.active) return false;
        const ReticleComponent& r = w.reticle(0);
        return fabsf(r.x - t.screenX) <= t.screenHalfW * 0.5f
            && fabsf(r.y - t.screenY) <= t.screenHalfH * 0.5f;
    };
    _steps.push_back({onTarget, steer, budgetTicks, "aimAt"});
    return *this;
}

ScriptedInput& ScriptedInput::holdUntil(Predicate p, int budgetTicks) {
    _steps.push_back({[p](const World& w, int) { return p(w); },
                      [](const World&, InputState&) {},
                      budgetTicks, "holdUntil"});
    return *this;
}

ScriptedInput& ScriptedInput::fire() {
    // Fire is level-triggered behind kFireCooldown, so one tick of press is one
    // shot; run() narrows apply to the first tick of the step. The two released
    // ticks after it keep edge-gated consumers (the join scan, the play-again
    // gate) seeing a clean release.
    _steps.push_back({[](const World&, int spent) { return spent >= 3; },
                      [](const World&, InputState& in) { in.fire = true; },
                      4, "fire"});
    return *this;
}

ScriptedInput& ScriptedInput::fireWhen(Predicate p, int budgetTicks) {
    holdUntil(p, budgetTicks);
    // Press on the very tick the predicate went true.
    _steps.push_back({[](const World&, int spent) { return spent >= 3; },
                      [](const World&, InputState& in) { in.fire = true; },
                      4, "fireWhen/press"});
    return *this;
}

ScriptedInput& ScriptedInput::trackAndFireWhen(int targetIndex, Predicate p, int budgetTicks) {
    auto fired = std::make_shared<int>(-1);   // tick within the step when we pressed
    auto apply = [targetIndex, p, fired](const World& w, InputState& in) {
        const TargetComponent& t = w.target(targetIndex);
        const ReticleComponent& r = w.reticle(0);
        in.stickX = std::clamp((t.screenX - r.x) * 40.f, -1.f, 1.f);
        in.stickY = std::clamp((t.screenY - r.y) * 40.f, -1.f, 1.f);
    };
    auto done = [p, fired, apply](const World& w, int spent) {
        if (*fired >= 0) return spent >= *fired + 3;   // clean release after the shot
        return false;
    };
    // The press decision has to happen where the input is built, so fold it in.
    auto applyWithFire = [apply, p, fired](const World& w, InputState& in) {
        apply(w, in);
        if (*fired < 0 && p(w)) { in.fire = true; *fired = 0; }
    };
    _steps.push_back({done, applyWithFire, budgetTicks, "trackAndFireWhen"});
    return *this;
}

bool ScriptedInput::run(World &world, int maxTicks) {
    _failure.clear();
    for (Step &step : _steps) {
        int spent = 0;
        bool pressOnFirstTickOnly = (step.label == "fire" || step.label == "fireWhen/press");
        while (!step.done(world, spent)) {
            if (spent >= step.budget) {
                _failure = "step '" + step.label + "' exhausted its budget of "
                         + std::to_string(step.budget) + " ticks";
                return false;
            }
            if (_ticksRun >= maxTicks) {
                _failure = "script exceeded maxTicks (" + std::to_string(maxTicks)
                         + ") during step '" + step.label + "'";
                return false;
            }
            InputState in{};
            if (!pressOnFirstTickOnly || spent == 0) step.apply(world, in);
            world.set_input(in, _player);
            world.update(kScriptDt);
            ++spent;
            ++_ticksRun;
        }
    }
    return true;
}

namespace Predicates {

ScriptedInput::Predicate interruptWindowOpen() {
    return [](const World& w) {
        for (EntityID id = 0; id < w.entity_count(); ++id) {
            if (!w.has_component<DinoBehaviorComponent>(id)) continue;
            const DinoBehaviorComponent& d = w.get_component<DinoBehaviorComponent>(id);
            if (d.interruptWindowOpen) return true;
        }
        return false;
    };
}

ScriptedInput::Predicate anyDinoInState(DinoBehaviorState s) {
    return [s](const World& w) {
        for (EntityID id = 0; id < w.entity_count(); ++id) {
            if (!w.has_component<DinoBehaviorComponent>(id)) continue;
            const DinoBehaviorComponent& d = w.get_component<DinoBehaviorComponent>(id);
            if (d.activeInEncounter && d.state == s) return true;
        }
        return false;
    };
}

ScriptedInput::Predicate interruptWindowOpenForTarget(int targetIndex) {
    return [targetIndex](const World& w) {
        for (EntityID id = 0; id < w.entity_count(); ++id) {
            if (!w.has_component<DinoBehaviorComponent>(id)) continue;
            const DinoBehaviorComponent& d = w.get_component<DinoBehaviorComponent>(id);
            if (d.targetIndex == targetIndex && d.interruptWindowOpen) return true;
        }
        return false;
    };
}

ScriptedInput::Predicate targetActive(int targetIndex) {
    return [targetIndex](const World& w) { return w.target(targetIndex).active; };
}

}
