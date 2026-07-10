#import <XCTest/XCTest.h>
#include "Simulation/Systems/DinoBehaviorSystem.h"
#include "Simulation/World.h"

@interface HealthTests : XCTestCase
@end

@implementation HealthTests

static EntityID findDino(World& world) {
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (world.has_component<DinoBehaviorComponent>(id)) return id;
    }
    return kInvalidEntity;
}

static void tick(World& world, int count) {
    for (int i = 0; i < count; ++i) {
        world.update(1.f / 120.f, 1.f / 120.f);
    }
}

static void placeWithinAttackRange(World& world, DinoBehaviorComponent& dino) {
    world.target(dino.targetIndex).railDistance =
        world.rail_camera().distance - dino.attackRange + 0.5f;
}

// Mirrors DinoBehaviorTests' test_missLetsAttackClipCompleteNormally tick
// counts (known to carry an Attack clip through to clipDone) and additionally
// checks that a landed (unopposed) attack actually costs player 0 health.
- (void)test_dinoAttackLandingUnopposedDamagesPlayer {
    World world;
    EntityID dinoId = findDino(world);
    XCTAssertNotEqual(dinoId, kInvalidEntity);

    DinoBehaviorComponent& dino = world.get_component<DinoBehaviorComponent>(dinoId);
    dino.idleDuration = 0.f;
    dino.jumpReactionDuration = 0.1f;
    placeWithinAttackRange(world, dino);
    int startHealth = world.player_health(0).health;

    tick(world, 5);
    dino.idleDuration = 5.f;
    tick(world, 40);

    XCTAssertEqual(dino.lastOutcome, DinoInterruptOutcome::Failed);
    XCTAssertEqual(world.player_health(0).health, startHealth - dino.attackDamage);
    XCTAssertFalse(world.player_health(0).sittingOut);
}

- (void)test_damagePlayerHonorsPostHitInvulnerabilityWindow {
    World world;
    int startHealth = world.player_health(0).health;

    world.damage_player(0, 20);
    XCTAssertEqual(world.player_health(0).health, startHealth - 20);

    // A second hit landing right after the first must not also connect —
    // otherwise several dinos finishing an attack in the same moment could
    // stack into an instant, unavoidable death.
    world.damage_player(0, 20);
    XCTAssertEqual(world.player_health(0).health, startHealth - 20);
}

- (void)test_healthReachingZeroEntersGameOverAndFreezesRail {
    World world;
    float distanceBefore = world.rail_camera().distance;

    world.damage_player(0, 1000);
    XCTAssertTrue(world.player_health(0).sittingOut);
    XCTAssertEqual(world.player_health(0).health, 0);

    // Player 0 is the only active reticle by default in this scenario? No —
    // reset_m1_scene activates both P1 and P2, so sitting out P1 alone would
    // NOT freeze the rail (P2 is still in). Deactivate P2 first so this test
    // exercises the true "everyone is out" freeze condition.
    world.reticle(1).active = false;

    tick(world, 60);
    XCTAssertEqualWithAccuracy(world.rail_camera().distance, distanceBefore, 0.0001f);
}

- (void)test_continuePressResetsHealthAndUnfreezesRail {
    World world;
    world.reticle(1).active = false; // isolate to a 1P scenario
    world.damage_player(0, 1000);
    XCTAssertTrue(world.player_health(0).sittingOut);

    InputState input = {};
    input.fire = true;
    world.set_input(input, 0); // player 0's own fire press "inserts the coin"

    tick(world, 1);
    XCTAssertFalse(world.player_health(0).sittingOut);
    XCTAssertEqual(world.player_health(0).health, world.player_health(0).maxHealth);

    float distanceAfterContinue = world.rail_camera().distance;
    tick(world, 10);
    XCTAssertGreaterThan(world.rail_camera().distance, distanceAfterContinue);
}

// Premise 8: "a depleted player sits out (spectates, reticle hidden) while
// their partner continues solo." P1 depleted must not freeze P2's run, and
// must not show the shared GAME OVER panel condition.
- (void)test_onePlayerDepletedInTwoPlayerLetsPartnerContinue {
    World world;
    XCTAssertTrue(world.reticle(0).active);
    XCTAssertTrue(world.reticle(1).active); // 2P is active by default

    world.damage_player(0, 1000);
    XCTAssertTrue(world.player_health(0).sittingOut);
    XCTAssertFalse(world.player_health(1).sittingOut);
    XCTAssertTrue(world.any_player_active_and_not_sitting_out());

    float distanceBefore = world.rail_camera().distance;
    tick(world, 60);
    XCTAssertGreaterThan(world.rail_camera().distance, distanceBefore);

    // P1's stick input must not move their now-hidden reticle (fire is
    // deliberately excluded here — that's the revive input, tested by
    // test_continuePressResetsHealthAndUnfreezesRail and the simultaneous-
    // depletion test below, not a "does aiming still work" case).
    InputState input = {};
    input.stickX = 1.f;
    world.set_input(input, 0);
    float p1XBefore = world.reticle(0).x;
    tick(world, 1);
    XCTAssertEqual(world.reticle(0).x, p1XBefore);
}

// Both players depleted in the same tick: both sit out, the shared "everyone
// is out" condition goes true (freezing rail/dinos — covered by
// test_healthReachingZeroEntersGameOverAndFreezesRail for the 1P case), and
// either player's own fire press revives only themselves, not their partner.
- (void)test_bothPlayersDepletedSimultaneouslyThenEitherContinuesAlone {
    World world;
    world.damage_player(0, 1000);
    world.damage_player(1, 1000);
    XCTAssertTrue(world.player_health(0).sittingOut);
    XCTAssertTrue(world.player_health(1).sittingOut);
    XCTAssertFalse(world.any_player_active_and_not_sitting_out());

    InputState fire = {};
    fire.fire = true;
    world.set_input(fire, 1); // only P2 presses fire

    tick(world, 1);
    XCTAssertTrue(world.player_health(0).sittingOut);  // P1 still out
    XCTAssertFalse(world.player_health(1).sittingOut); // P2 revived themselves
    XCTAssertTrue(world.any_player_active_and_not_sitting_out());
}

@end
