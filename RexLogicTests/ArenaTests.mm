#import <XCTest/XCTest.h>
#include "Simulation/World.h"
#include "Simulation/Systems/DinoBehaviorSystem.h"

// The post-boss arena: when the boss flees (and the chart scripts an arena),
// the rail camera stops and raptors rush in wave-by-wave; each wave clears only
// once every raptor in it is dead, and the last wave completes the level.

@interface ArenaTests : XCTestCase
@end

@implementation ArenaTests

static void tick(World& world, int count) {
    for (int i = 0; i < count; ++i) world.update(1.f / 120.f, 1.f / 120.f);
}

static int activeArenaRaptors(World& world) {
    int n = 0;
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.has_component<DinoBehaviorComponent>(id)) continue;
        const DinoBehaviorComponent& dino = world.get_component<DinoBehaviorComponent>(id);
        if (dino.arena && dino.activeInEncounter) ++n;
    }
    return n;
}

// Simulates the wave being wiped out (bypasses the multi-second death anim so
// the progression logic can be exercised quickly).
static void killAllArenaRaptors(World& world) {
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.has_component<DinoBehaviorComponent>(id)) continue;
        DinoBehaviorComponent& dino = world.get_component<DinoBehaviorComponent>(id);
        if (dino.arena && dino.activeInEncounter) {
            dino.activeInEncounter = false;
            dino.state = DinoBehaviorState::Dormant;
        }
    }
}

// Ticks until the current wave has spawned (or a cap), returning its index.
static int waitForWaveSpawn(World& world) {
    for (int i = 0; i < 400 && activeArenaRaptors(world) == 0; ++i) tick(world, 1);
    return world.arena().waveIndex;
}

- (void)test_enterArenaStopsCameraAndStaysInPlay {
    World world;
    world.rail_camera().speed = 1.2f;
    XCTAssertFalse(world.arena_active());

    world.enter_arena();

    XCTAssertTrue(world.arena_active());
    XCTAssertEqualWithAccuracy(world.rail_camera().speed, 0.f, 0.0001f);
    XCTAssertFalse(world.level_complete()); // holdout, not done yet
}

- (void)test_defaultChartScriptsThreeArenaWaves {
    World world;
    XCTAssertEqual(world.chart().arenaWaveCount, 3);
}

- (void)test_arenaAdvancesWaveByWaveThenCompletesLevel {
    World world;
    XCTAssertEqual(world.chart().arenaWaveCount, 3);
    world.enter_arena();

    // Wave 0 spawns after the opening beat.
    XCTAssertEqual(waitForWaveSpawn(world), 0);
    XCTAssertGreaterThan(activeArenaRaptors(world), 0);

    // Clearing a wave advances to the next.
    killAllArenaRaptors(world);
    for (int i = 0; i < 400 && world.arena().waveIndex == 0; ++i) tick(world, 1);
    XCTAssertEqual(world.arena().waveIndex, 1);
    XCTAssertGreaterThan(activeArenaRaptors(world), 0);

    killAllArenaRaptors(world);
    for (int i = 0; i < 400 && world.arena().waveIndex == 1; ++i) tick(world, 1);
    XCTAssertEqual(world.arena().waveIndex, 2);
    XCTAssertGreaterThan(activeArenaRaptors(world), 0);

    // Clearing the LAST wave completes the level.
    XCTAssertFalse(world.level_complete());
    killAllArenaRaptors(world);
    for (int i = 0; i < 600 && !world.level_complete(); ++i) tick(world, 1);
    XCTAssertTrue(world.level_complete());
    XCTAssertFalse(world.arena_active());
}

- (void)test_arenaWaveDoesNotClearOnItsOwn {
    // Arena raptors loop attacking (re-approach instead of going dormant), so a
    // wave can't be waited out — it clears only when the player kills them.
    World world;
    world.enter_arena();
    XCTAssertEqual(waitForWaveSpawn(world), 0);
    int spawned = activeArenaRaptors(world);
    XCTAssertGreaterThan(spawned, 0);

    // Several seconds pass (long enough for an attack/retreat cycle) with no
    // kills — the wave must still be out.
    tick(world, 600); // 5s
    XCTAssertEqual(world.arena().waveIndex, 0);
    XCTAssertGreaterThan(activeArenaRaptors(world), 0);
}

- (void)test_spawnedArenaRaptorsSpreadAcrossLanes {
    // "Different angles": the opening wave's raptors occupy distinct lateral
    // lanes rather than stacking.
    World world;
    world.enter_arena();
    XCTAssertEqual(waitForWaveSpawn(world), 0);

    std::vector<float> lanes;
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.has_component<DinoBehaviorComponent>(id)) continue;
        const DinoBehaviorComponent& dino = world.get_component<DinoBehaviorComponent>(id);
        if (dino.arena && dino.activeInEncounter && dino.targetIndex < kM1MaxTargets) {
            lanes.push_back(world.target(dino.targetIndex).baseLateralOffset);
        }
    }
    XCTAssertGreaterThanOrEqual((int)lanes.size(), 2);
    // At least one clearly-left and one clearly-right of center.
    bool left = false, right = false;
    for (float x : lanes) { if (x < -0.5f) left = true; if (x > 0.5f) right = true; }
    XCTAssertTrue(left);
    XCTAssertTrue(right);
}

@end
