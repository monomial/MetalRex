#import <XCTest/XCTest.h>
#include "Simulation/World.h"
#include "Simulation/Systems/ReticleSystem.h"

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
    World world;
    world.reticle(0).x = 0.5f;
    world.reticle(0).y = 0.5f;
    InputState input = {};
    input.stickX = 1.f;
    world.set_input(input, 0);
    world.update(1.f / 120.f, 1.f / 120.f);
    float frictionDelta = world.reticle(0).x - 0.5f;

    World clearWorld;
    clearWorld.reticle(0).x = 0.95f;
    clearWorld.reticle(0).y = 0.95f;
    clearWorld.set_input(input, 0);
    world.update(1.f / 120.f, 1.f / 120.f);
    clearWorld.update(1.f / 120.f, 1.f / 120.f);
    float clearDelta = clearWorld.reticle(0).x - 0.95f;

    XCTAssertGreaterThan(clearDelta, frictionDelta);
    XCTAssertLessThan(world.reticle(0).x, 0.6f);
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

    XCTAssertTrue(world.target(0).wasHit);
}

- (void)test_movingTargetUpdatesWhileCameraDolliesForward {
    World world;
    world.update(1.f / 120.f, 1.f / 120.f);
    float firstCameraZ = world.rail_camera().dollyZ;
    float firstX = world.target(3).screenX;

    for (int i = 0; i < 60; ++i) {
        world.update(1.f / 120.f, 1.f / 120.f);
    }

    XCTAssertGreaterThan(world.rail_camera().dollyZ, firstCameraZ);
    XCTAssertNotEqualWithAccuracy(world.target(3).screenX, firstX, 0.0001f);
    XCTAssertTrue(world.target(3).active);
}

@end
