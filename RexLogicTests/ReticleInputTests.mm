#import <XCTest/XCTest.h>
#include "Simulation/World.h"
#include "Simulation/Systems/ReticleSystem.h"
#include <math.h>

@interface ReticleInputTests : XCTestCase
@end

@implementation ReticleInputTests

- (void)setUp {
    ReticleTuning tuning = {};
    ReticleSystem_set_tuning(tuning);
}

- (void)test_stickOnlyInputMovesReticleInScreenSpace {
    World world;
    world.reticle(0).x = 0.2f;
    world.reticle(0).y = 0.8f;
    InputState input = {};
    input.stickX = 1.f;
    input.stickY = -0.5f;
    world.set_input(input, 0);

    world.update(1.f / 120.f, 1.f / 120.f);

    const ReticleComponent& reticle = world.reticle(0);
    XCTAssertGreaterThan(reticle.x, 0.2f);
    XCTAssertLessThan(reticle.y, 0.8f);
}

- (void)test_gyroDeltaMovesSameScreenSpaceReticle {
    World world;
    InputState input = {};
    input.gyroDeltaX = 0.03f;
    input.gyroDeltaY = 0.02f;
    world.set_input(input, 0);

    world.update(1.f / 120.f, 1.f / 120.f);

    const ReticleComponent& reticle = world.reticle(0);
    XCTAssertGreaterThan(reticle.x, 0.5f);
    XCTAssertGreaterThan(reticle.y, 0.5f);
    XCTAssertTrue(reticle.gyroAvailable);
}

- (void)test_recenterReturnsToMiddleAndClearsGyroDrift {
    World world;
    InputState input = {};
    input.gyroDeltaX = 0.05f;
    world.set_input(input, 0);
    world.update(1.f / 120.f, 1.f / 120.f);

    input = {};
    input.recenter = true;
    world.set_input(input, 0);
    world.update(1.f / 120.f, 1.f / 120.f);

    const ReticleComponent& reticle = world.reticle(0);
    XCTAssertEqualWithAccuracy(reticle.x, 0.5f, 0.0001f);
    XCTAssertEqualWithAccuracy(reticle.y, 0.5f, 0.0001f);
    XCTAssertEqualWithAccuracy(reticle.gyroDriftX, 0.f, 0.0001f);
}

- (void)test_reticleClampsAtScreenEdges {
    World world;
    InputState input = {};
    input.stickX = 10.f;
    input.stickY = 10.f;
    world.set_input(input, 0);

    for (int i = 0; i < 2000; ++i) {
        world.update(1.f / 120.f, 1.f / 120.f);
    }

    const ReticleComponent& reticle = world.reticle(0);
    XCTAssertLessThanOrEqual(reticle.x, 1.f);
    XCTAssertLessThanOrEqual(reticle.y, 1.f);
    XCTAssertGreaterThanOrEqual(reticle.x, 0.f);
    XCTAssertGreaterThanOrEqual(reticle.y, 0.f);
}

- (void)test_tieredSmoothingOnlyDampsNearStillnessGyro {
    ReticleTuning tuning = {};
    tuning.stillnessThreshold = 0.01f;
    tuning.stillnessSmoothingAlpha = 0.1f;
    ReticleSystem_set_tuning(tuning);

    World world;
    InputState input = {};
    input.gyroDeltaX = 0.002f;
    world.set_input(input, 0);
    world.update(1.f / 120.f, 1.f / 120.f);
    float dampedDelta = world.reticle(0).x - 0.5f;

    World crispWorld;
    input.gyroDeltaX = 0.03f;
    crispWorld.set_input(input, 0);
    crispWorld.update(1.f / 120.f, 1.f / 120.f);
    float crispDelta = crispWorld.reticle(0).x - 0.5f;

    XCTAssertGreaterThan(dampedDelta, 0.f);
    XCTAssertLessThan(dampedDelta, 0.002f * tuning.gyroSensitivityH);
    XCTAssertEqualWithAccuracy(crispDelta, 0.03f * tuning.gyroSensitivityH, 0.0001f);
}

- (void)test_stickOnlyFallbackFrictionReducesReticleSpeedOverTargetWithoutSnapping {
    // A real target must be present and active for the over-target friction
    // path to trigger at all — a prior version of this test set the reticle's
    // position directly with no TargetComponent nearby, so overTarget was
    // never true and this never actually exercised the friction/magnet code.
    World world;
    world.update(1.f / 120.f, 1.f / 120.f);
    const TargetComponent& target = world.target(0);
    XCTAssertTrue(target.active);
    world.reticle(0).x = target.screenX;
    world.reticle(0).y = target.screenY;

    InputState input = {};
    input.stickX = 1.f;
    world.set_input(input, 0);
    world.update(1.f / 120.f, 1.f / 120.f);
    float frictionDelta = world.reticle(0).x - target.screenX;

    World clearWorld;
    clearWorld.reticle(0).x = 0.f;
    clearWorld.reticle(0).y = 0.f;
    clearWorld.set_input(input, 0);
    clearWorld.update(1.f / 120.f, 1.f / 120.f);
    float clearDelta = clearWorld.reticle(0).x - 0.f;

    XCTAssertGreaterThan(clearDelta, frictionDelta);
}

- (void)test_stickOnlyFallbackAssistDoesNotOpposeInitialEscapeTick {
    // Regresses a real bug: an earlier version of the magnet pull got
    // STRONGER the closer the reticle was to the target — i.e. strongest
    // exactly at distance zero, which is exactly where a player trying to
    // move away starts from. Combined with friction cutting their own input,
    // the net effect could stall or reverse a deliberate escape attempt on
    // the very first tick, which reads as a soft snap-lock.
    World world;
    world.update(1.f / 120.f, 1.f / 120.f);
    const TargetComponent& target = world.target(0);
    world.reticle(0).x = target.screenX;
    world.reticle(0).y = target.screenY;

    InputState input = {};
    input.stickX = 1.f;
    world.set_input(input, 0);
    world.update(1.f / 120.f, 1.f / 120.f);

    XCTAssertGreaterThan(world.reticle(0).x, target.screenX);
}

- (void)test_stickOnlyFallbackAssistNeverPreventsEscapingATarget {
    // Same bug, sustained: holding a deliberate escape direction for a full
    // second must actually leave the target's box, not hover near it forever.
    World world;
    world.update(1.f / 120.f, 1.f / 120.f);
    const TargetComponent& target = world.target(0);
    world.reticle(0).x = target.screenX;
    world.reticle(0).y = target.screenY;

    InputState input = {};
    input.stickX = 1.f;
    world.set_input(input, 0);
    for (int i = 0; i < 120; ++i) {
        world.update(1.f / 120.f, 1.f / 120.f);
    }

    float dist = fabsf(world.reticle(0).x - target.screenX);
    XCTAssertGreaterThan(dist, target.screenHalfW * 2.f);
}

- (void)test_fireMarksTargetHitByReticleScreenBounds {
    World world;
    world.update(1.f / 120.f, 1.f / 120.f);
    const TargetComponent& target = world.target(0);
    world.reticle(0).x = target.screenX;
    world.reticle(0).y = target.screenY;

    InputState input = {};
    input.fire = true;
    world.set_input(input, 0);
    world.update(1.f / 120.f, 1.f / 120.f);

    // target.wasHit is a same-tick pulse: DinoBehaviorSystem_update, which
    // runs later in this same tick, consumes and clears it to apply
    // damage/score before this assertion ever gets to see it — so it always
    // reads false here regardless of whether the hit registered. Assert the
    // durable side effect (score) instead of the transient flag. Not exactly
    // 10/1: the fire loop checks every target against the reticle position
    // in one pass, and at tick 1 the other freshly-spawned raptors can still
    // overlap target(0)'s screen box, so this one shot can also register
    // against them (separately observed — see chat) — assert "at least one
    // hit landed" rather than an exact count.
    XCTAssertGreaterThan(world.score(0).score, 0);
    XCTAssertGreaterThanOrEqual(world.score(0).shotsHit, 1);
}

- (void)test_movingTargetUpdatesWhileRailCameraMovesForward {
    World world;
    world.update(1.f / 120.f, 1.f / 120.f);
    float firstCameraDistance = world.rail_camera().distance;
    float firstX = world.target(3).screenX;

    for (int i = 0; i < 60; ++i) {
        world.update(1.f / 120.f, 1.f / 120.f);
    }

    XCTAssertGreaterThan(world.rail_camera().distance, firstCameraDistance);
    XCTAssertNotEqualWithAccuracy(world.target(3).screenX, firstX, 0.0001f);
    XCTAssertTrue(world.target(3).active);
}

@end
