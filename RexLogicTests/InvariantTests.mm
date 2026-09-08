#import <XCTest/XCTest.h>
#import "ScenarioBuilder.h"
#import "ScriptedInput.h"
#include "Simulation/World.h"
#include "Simulation/Systems/ReticleSystem.h"
#include <cmath>
#include <string>

// Properties that must hold on EVERY tick, checked across scripted scenarios
// and a seeded pseudo-random input stream.
//
// Fuzzing is only worth doing because the sim is deterministic (M4b): a
// failure reproduces exactly from its seed, and the offending run is dumped
// as a replay file. A fuzz failure you cannot replay is a bug report with no
// repro, so the dump is not optional.
@interface InvariantTests : XCTestCase
@end
@implementation InvariantTests

- (void)setUp { ReticleSystem_set_tuning({}); }
- (void)tearDown { ReticleSystem_set_tuning({}); }

static bool finite2(float a, float b) { return std::isfinite(a) && std::isfinite(b); }

// Returns an empty string when every invariant holds this tick.
static std::string checkTick(const World& w) {
    for (int p = 0; p < kRexMaxPlayers; ++p) {
        const ReticleComponent& r = w.reticle(p);
        if (!finite2(r.x, r.y)) return "reticle " + std::to_string(p) + " not finite";
        if (r.active && (r.x < -0.001f || r.x > 1.001f || r.y < -0.001f || r.y > 1.001f))
            return "reticle " + std::to_string(p) + " escaped [0,1]";
        const PlayerHealthState& h = w.player_health(p);
        if (h.health < 0) return "player " + std::to_string(p) + " health negative";
        if (!std::isfinite(h.invulnTime) || !std::isfinite(h.hitFlashTime))
            return "player " + std::to_string(p) + " timer not finite";
    }
    for (int i = 0; i < kM1MaxTargets; ++i) {
        const TargetComponent& t = w.target(i);
        if (!finite2(t.screenX, t.screenY)) return "target " + std::to_string(i) + " screen pos not finite";
        if (!finite2(t.worldX, t.worldZ)) return "target " + std::to_string(i) + " world pos not finite";
        if (t.screenHalfW < 0.f || t.screenHalfH < 0.f)
            return "target " + std::to_string(i) + " negative half-extent";
    }
    for (EntityID id = 0; id < w.entity_count(); ++id) {
        if (!w.has_component<DinoBehaviorComponent>(id)) continue;
        const DinoBehaviorComponent& d = w.get_component<DinoBehaviorComponent>(id);
        if (d.health > d.maxHealth) return "dino health exceeds max";
        if (d.health < 0) return "dino health negative";
        // A dino outside its attack cycle must never claim an open interrupt
        // window: the tint would then promise points the scoring cannot pay.
        bool inCycle = d.state == DinoBehaviorState::Tell || d.state == DinoBehaviorState::Attack;
        if (d.interruptWindowOpen && !inCycle) return "interruptWindowOpen outside Tell/Attack";
        if (d.interruptWindowOpen && d.isBoss) return "boss claims an interrupt window";
    }
    return {};
}

- (void)runWorld:(World&)world ticks:(int)ticks label:(NSString*)label {
    for (int t = 0; t < ticks; ++t) {
        world.update(1.f / 120.f);
        std::string bad = checkTick(world);
        if (!bad.empty())
            XCTFail(@"%@: invariant broke at tick %d: %s", label, t, bad.c_str());
        if (!bad.empty()) return;
    }
}

- (void)test_invariantsHoldAcrossAScriptedWave {
    World world;
    Scenario().onlyWave(@"pack-test").noBoss().applyTo(world);
    [self runWorld:world ticks:2000 label:@"pack wave"];
}

- (void)test_invariantsHoldThroughBossAndArena {
    World world;
    Scenario().applyTo(world);   // the full chart: waves, boss QTE, arena
    [self runWorld:world ticks:6000 label:@"full chart"];
}

- (void)test_seededFuzzInputKeepsInvariantsAndDumpsOnFailure {
    for (uint32_t seed : {1u, 7u, 4242u}) {
        World world;
        Scenario().seed(seed).applyTo(world);
        world.begin_recording(4);

        uint32_t rng = seed ? seed : 1u;
        auto next = [&rng] { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; };

        for (int t = 0; t < 3000; ++t) {
            InputState in{};
            in.stickX = (float)(next() % 2001) / 1000.f - 1.f;
            in.stickY = (float)(next() % 2001) / 1000.f - 1.f;
            in.fire = (next() % 8) == 0;
            in.recenter = (next() % 500) == 0;
            world.set_input(in, 0);
            world.update(1.f / 120.f);

            std::string bad = checkTick(world);
            if (!bad.empty()) {
                // Dump the exact run so the failure is reproducible.
                NSString *dump = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                  [NSString stringWithFormat:@"fuzz-seed-%u.replay", seed]];
                std::string err;
                if (const InputRecording *rec = world.recording())
                    rec->saveToFile(dump.UTF8String, &err);
                XCTFail(@"fuzz seed %u broke an invariant at tick %d: %s (replay: %@)",
                        seed, t, bad.c_str(), dump);
                break;
            }
        }
    }
}

@end
