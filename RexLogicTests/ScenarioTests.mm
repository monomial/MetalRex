#import <XCTest/XCTest.h>
#import "ScenarioBuilder.h"
#import "ScriptedInput.h"
#include "Simulation/World.h"
#include <algorithm>
#include <cmath>
#include "Simulation/Systems/ReticleSystem.h"

// Proves the two authoring tools work together on the case they exist for:
// scoring a 50-point interrupt, which needs the reticle steered onto a live
// raptor through the real input path and the trigger pulled inside a ~145ms
// window. Before these tools that test was not practically writable.
@interface ScenarioTests : XCTestCase
@end
@implementation ScenarioTests

- (void)setUp { ReticleSystem_set_tuning({}); }
- (void)tearDown { ReticleSystem_set_tuning({}); }

- (void)test_scenarioBuilderProducesAStableChartIdentity {
    LevelChart a = Scenario().onlyWave(@"pack-test").noBoss().build();
    LevelChart b = Scenario().onlyWave(@"pack-test").noBoss().build();
    // Same declarative scenario -> same bytes -> same hash. If this drifts,
    // every replay header built on a scenario becomes unreproducible.
    XCTAssertEqual(a.sourceHash, b.sourceHash);
    XCTAssertEqual(a.events.size(), 1u);
    XCTAssertEqual(a.arenaWaveCount, b.arenaWaveCount);
}

- (void)test_scriptedAimAndFireScoresTheInterrupt {
    World world;
    // solo-test, not pack-test: since 3e64496 a bullet hits only the front-most
    // dino, so in a 3-raptor pack the shot can land on whichever raptor occludes
    // the one being tracked — and that one is not in its interrupt window. One
    // raptor makes the assertion mean what it says.
    Scenario().onlyWave(@"solo-test").noBoss().noArena().applyTo(world);
    // score_timeline() only accumulates while recording or replaying
    // (World.mm's `if (_recording || _replay)`), and recording also makes the
    // scripted run exportable for REX_REPLAY in the real renderer.
    world.begin_recording(4);

    ScriptedInput script;
    script.holdUntil(Predicates::targetActive(0))
          .trackAndFireWhen(0, Predicates::interruptWindowOpenForTarget(0));

    XCTAssertTrue(script.run(world), @"%s", script.failureReason().c_str());

    int interrupts = 0;
    for (const auto& e : world.score_timeline())
        if (e.event == DinoScoreEvent::InterruptSuccess) ++interrupts;
    XCTAssertGreaterThanOrEqual(interrupts, 1,
        @"scripted fire inside the interrupt window should score InterruptSuccess");
}

- (void)test_scriptFailsLoudlyRatherThanPassingVacuously {
    World world;
    Scenario().onlyWave(@"pack-test").noBoss().noArena().applyTo(world);
    // A predicate that can never hold must exhaust its budget and report,
    // not quietly succeed — a silent no-op script is a fake green test.
    ScriptedInput script;
    script.holdUntil([](const World&) { return false; }, /*budget*/50);
    XCTAssertFalse(script.run(world));
    XCTAssertTrue(script.failureReason().find("exhausted") != std::string::npos,
                  @"%s", script.failureReason().c_str());
}


@end
