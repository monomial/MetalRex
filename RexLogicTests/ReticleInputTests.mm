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

static void activateTarget(World& world, int targetIndex) {
    TargetComponent& target = world.target(targetIndex);
    target.active = true;
    target.moving = true;
}

static void activateDinoForTarget(World& world, int targetIndex) {
    activateTarget(world, targetIndex);
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.has_component<DinoBehaviorComponent>(id)) continue;
        DinoBehaviorComponent& dino = world.get_component<DinoBehaviorComponent>(id);
        if (dino.targetIndex != targetIndex) continue;
        dino.activeInEncounter = true;
        dino.state = DinoBehaviorState::Approach;
        dino.holdDuration = 100.f;
        break;
    }
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
    activateTarget(world, 0);
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
    activateTarget(world, 0);
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
    activateTarget(world, 0);
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
    activateDinoForTarget(world, 0);
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
    // durable side effect (score) instead of the transient flag. Exactly
    // 10/1 now: a bullet hits only the single front-most target whose box
    // contains the reticle, so overlapping boxes (the always-active T-Rex's
    // large box can contain this raptor's center) no longer double-count.
    XCTAssertEqual(world.score(0).score, 10);
    XCTAssertEqual(world.score(0).shotsHit, 1);
}

- (void)test_oneShotHitsOnlyTheFrontMostOverlappingTarget {
    // A raptor standing inside the T-Rex's much larger screen box must
    // shield it: one bullet, one dino. The old fire loop marked EVERY
    // containing box hit, so shooting the raptor also chipped the boss.
    World world;
    activateDinoForTarget(world, 0);
    activateDinoForTarget(world, 6); // boss arrives late by chart; force it in
    // Park the raptor directly in front of the T-Rex: same lane, same weave
    // phase (raptor slot 0 spawns at lane -1.9 by default, nowhere near the
    // boss's centered box).
    world.target(0).baseLateralOffset = world.target(6).baseLateralOffset;
    world.target(0).lateralOffset = world.target(6).lateralOffset;
    world.target(0).timerOffset = world.target(6).timerOffset;
    world.update(1.f / 120.f, 1.f / 120.f);

    const TargetComponent& raptorTarget = world.target(0);
    const TargetComponent& trexTarget = world.target(6);
    world.reticle(0).x = raptorTarget.screenX;
    world.reticle(0).y = raptorTarget.screenY;

    // Premise check — the raptor's center must actually sit inside the
    // T-Rex's box, or this test passes without exercising the overlap.
    XCTAssertTrue(trexTarget.active);
    XCTAssertLessThanOrEqual(fabsf(raptorTarget.screenX - trexTarget.screenX),
                             trexTarget.screenHalfW);
    XCTAssertLessThanOrEqual(fabsf(raptorTarget.screenY - trexTarget.screenY),
                             trexTarget.screenHalfH);
    // And the raptor must be the front-most of the two (nearer the camera).
    XCTAssertGreaterThan(raptorTarget.railDistance, trexTarget.railDistance);

    EntityID raptorId = kInvalidEntity;
    EntityID trexId = kInvalidEntity;
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.has_component<DinoBehaviorComponent>(id)) continue;
        const DinoBehaviorComponent& dino = world.get_component<DinoBehaviorComponent>(id);
        if (dino.targetIndex == 0) raptorId = id;
        if (dino.targetIndex == 6) trexId = id;
    }
    XCTAssertNotEqual(raptorId, kInvalidEntity);
    XCTAssertNotEqual(trexId, kInvalidEntity);
    int raptorHealthBefore = world.get_component<DinoBehaviorComponent>(raptorId).health;
    int trexHealthBefore = world.get_component<DinoBehaviorComponent>(trexId).health;

    InputState input = {};
    input.fire = true;
    world.set_input(input, 0);
    world.update(1.f / 120.f, 1.f / 120.f);

    XCTAssertEqual(world.get_component<DinoBehaviorComponent>(raptorId).health,
                   raptorHealthBefore - 1);
    XCTAssertEqual(world.get_component<DinoBehaviorComponent>(trexId).health,
                   trexHealthBefore);
}

- (void)test_movingTargetUpdatesWhileRailCameraMovesForward {
    World world;
    activateTarget(world, 3);
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
