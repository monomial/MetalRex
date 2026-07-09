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
// checks that a landed (unopposed) attack actually costs the player health.
- (void)test_dinoAttackLandingUnopposedDamagesPlayer {
    World world;
    EntityID dinoId = findDino(world);
    XCTAssertNotEqual(dinoId, kInvalidEntity);

    DinoBehaviorComponent& dino = world.get_component<DinoBehaviorComponent>(dinoId);
    dino.idleDuration = 0.f;
    dino.jumpReactionDuration = 0.1f;
    placeWithinAttackRange(world, dino);
    int startHealth = world.player_health().health;

    tick(world, 5);
    dino.idleDuration = 5.f;
    tick(world, 40);

    XCTAssertEqual(dino.lastOutcome, DinoInterruptOutcome::Failed);
    XCTAssertEqual(world.player_health().health, startHealth - dino.attackDamage);
    XCTAssertFalse(world.player_health().gameOver);
}

- (void)test_damagePlayerHonorsPostHitInvulnerabilityWindow {
    World world;
    int startHealth = world.player_health().health;

    world.damage_player(20);
    XCTAssertEqual(world.player_health().health, startHealth - 20);

    // A second hit landing right after the first must not also connect —
    // otherwise several dinos finishing an attack in the same moment could
    // stack into an instant, unavoidable death.
    world.damage_player(20);
    XCTAssertEqual(world.player_health().health, startHealth - 20);
}

- (void)test_healthReachingZeroEntersGameOverAndFreezesRail {
    World world;
    float distanceBefore = world.rail_camera().distance;

    world.damage_player(1000);
    XCTAssertTrue(world.player_health().gameOver);
    XCTAssertEqual(world.player_health().health, 0);

    tick(world, 60);
    XCTAssertEqualWithAccuracy(world.rail_camera().distance, distanceBefore, 0.0001f);
}

- (void)test_continuePressResetsHealthAndUnfreezesRail {
    World world;
    world.damage_player(1000);
    XCTAssertTrue(world.player_health().gameOver);

    InputState input = {};
    input.fire = true;
    world.set_input(input, 0); // player 0's reticle is active by default

    tick(world, 1);
    XCTAssertFalse(world.player_health().gameOver);
    XCTAssertEqual(world.player_health().health, world.player_health().maxHealth);

    float distanceAfterContinue = world.rail_camera().distance;
    tick(world, 10);
    XCTAssertGreaterThan(world.rail_camera().distance, distanceAfterContinue);
}

@end
