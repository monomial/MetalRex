#import <XCTest/XCTest.h>
#include "Simulation/World.h"

@interface TitleFlowTests : XCTestCase
@end

@implementation TitleFlowTests

static void tick(World& world, int count) {
    for (int i = 0; i < count; ++i) {
        world.update(1.f / 120.f, 1.f / 120.f);
    }
}

- (void)test_worldConstructsPlayingWithTwoPlayersForTests {
    World world;
    XCTAssertEqual(world.phase(), GamePhase::Playing);
    XCTAssertTrue(world.reticle(0).active);
    XCTAssertTrue(world.reticle(1).active);
}

- (void)test_titleFreezesGameplayAndHeldFireNeverStarts {
    World world;
    world.enter_title();
    XCTAssertEqual(world.phase(), GamePhase::Title);
    XCTAssertFalse(world.reticle(0).active);
    XCTAssertFalse(world.reticle(1).active);

    // Fire held from the very first tick (launch press / trigger mash):
    // must never join — the edge gate requires a release first.
    InputState held = {};
    held.fire = true;
    world.set_input(held, 0);
    float distanceBefore = world.rail_camera().distance;
    tick(world, 240);
    XCTAssertEqual(world.phase(), GamePhase::Title);
    XCTAssertFalse(world.reticle(0).active);
    XCTAssertEqualWithAccuracy(world.rail_camera().distance, distanceBefore, 0.0001f);
}

- (void)test_releaseThenPressJoinsSoloAndStarts {
    World world;
    world.enter_title();
    tick(world, 5); // fire released -> edge armed

    InputState press = {};
    press.fire = true;
    world.set_input(press, 0);
    tick(world, 1);

    XCTAssertEqual(world.phase(), GamePhase::Playing);
    XCTAssertTrue(world.reticle(0).active);
    // Solo start: P2 must NOT be dragged in — no ghost reticle.
    XCTAssertFalse(world.reticle(1).active);

    // Gameplay actually runs.
    float distanceBefore = world.rail_camera().distance;
    tick(world, 60);
    XCTAssertGreaterThan(world.rail_camera().distance, distanceBefore);
}

- (void)test_secondPlayerJoinsMidRunWithFreshSlot {
    World world;
    world.enter_title();
    tick(world, 5);
    InputState press = {};
    press.fire = true;
    world.set_input(press, 0);
    tick(world, 1);
    world.set_input(InputState{}, 0);
    tick(world, 300); // run in progress, P1 solo

    // Damage P1 so the fresh-slot contrast is observable.
    world.damage_player(0, 20);
    XCTAssertLessThan(world.player_health(0).health, world.player_health(0).maxHealth);

    world.set_input(press, 1);
    tick(world, 1);
    XCTAssertTrue(world.reticle(1).active);
    XCTAssertEqual(world.player_health(1).health, world.player_health(1).maxHealth);
    XCTAssertEqual(world.score(1).score, 0);
    // Mid-run join shares the run — it does NOT reset the scene.
    XCTAssertGreaterThan(world.rail_camera().distance, 8.5f);
}

- (void)test_playAgainPreservesSoloJoin {
    World world;
    world.enter_title();
    tick(world, 5);
    InputState press = {};
    press.fire = true;
    world.set_input(press, 0);
    tick(world, 1);
    world.set_input(InputState{}, 0);

    // Complete the level solo, then play again: still solo.
    world.complete_level();
    tick(world, 200); // past the 1.5s minimum display, fire released
    world.set_input(press, 0);
    tick(world, 5);

    XCTAssertFalse(world.level_complete());
    XCTAssertTrue(world.reticle(0).active);
    XCTAssertFalse(world.reticle(1).active);
}

- (void)test_titleStickTogglesModeSelectionEdgeGated {
    World world;
    world.enter_title();
    XCTAssertEqual(world.title_selection(), 0); // defaults to 1 PLAYER

    // Flick right: selects 2 PLAYERS once, not repeatedly while held.
    InputState right = {};
    right.stickX = 1.f;
    world.set_input(right, 0);
    tick(world, 30);
    XCTAssertEqual(world.title_selection(), 1);

    // Still held: no oscillation back.
    tick(world, 30);
    XCTAssertEqual(world.title_selection(), 1);

    // Return to neutral, then flick left: back to 1 PLAYER.
    world.set_input(InputState{}, 0);
    tick(world, 5);
    InputState left = {};
    left.stickX = -1.f;
    world.set_input(left, 0);
    tick(world, 5);
    XCTAssertEqual(world.title_selection(), 0);
}

- (void)test_confirmingTwoPlayersActivatesBothSlots {
    World world;
    world.enter_title();
    InputState right = {};
    right.stickX = 1.f;
    world.set_input(right, 0);
    tick(world, 5); // select 2 PLAYERS (also arms the fire edge via released fire)

    InputState press = {};
    press.fire = true;
    world.set_input(press, 0);
    tick(world, 1);

    XCTAssertEqual(world.phase(), GamePhase::Playing);
    XCTAssertTrue(world.reticle(0).active);
    XCTAssertTrue(world.reticle(1).active);
}

@end