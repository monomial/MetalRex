#import <XCTest/XCTest.h>
#include "Assets/CharacterLoader.h"
#include "Simulation/Systems/DinoBehaviorSystem.h"
#include "Simulation/Systems/AnimationSystem.h"
#include "Simulation/World.h"
#include <cmath>
#include <string>

@interface DinoBehaviorTests : XCTestCase
@end

@implementation DinoBehaviorTests

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

- (void)test_interruptWithinWindowCancelsAttackAndTransitionsToJumpReaction {
    World world;
    EntityID dinoId = findDino(world);
    XCTAssertNotEqual(dinoId, kInvalidEntity);

    DinoBehaviorComponent& dino = world.get_component<DinoBehaviorComponent>(dinoId);
    dino.idleDuration = 0.f;
    dino.interruptStartNormalized = 0.18f;
    dino.interruptEndNormalized = 0.60f;

    tick(world, 8);
    world.target(dino.targetIndex).wasHit = true;
    tick(world, 1);

    AnimationComponent& anim = world.get_component<AnimationComponent>(dinoId);
    XCTAssertEqual(dino.lastOutcome, DinoInterruptOutcome::Succeeded);
    XCTAssertTrue(dino.outcomeThisCycle);
    XCTAssertEqual(dino.state, DinoBehaviorState::Interrupted);
    XCTAssertEqual(anim.currentClip, CharacterClipSlot::Jump);
}

- (void)test_missLetsAttackClipCompleteNormally {
    World world;
    EntityID dinoId = findDino(world);
    XCTAssertNotEqual(dinoId, kInvalidEntity);

    DinoBehaviorComponent& dino = world.get_component<DinoBehaviorComponent>(dinoId);
    // idleDuration=0 only to start the FIRST attack without waiting — it must
    // not stay 0 for the whole test, or the post-miss Idle period is also
    // zero-length: the state machine re-enters Tell in the same tick it
    // reaches Idle, and "settled in Idle" is never observable. Bump it back
    // up once the first attack is safely underway (5 ticks, well short of
    // the ~31-tick fallback Attack duration) so the Idle it lands in *after*
    // the miss is actually one this test can catch.
    dino.idleDuration = 0.f;
    dino.jumpReactionDuration = 0.1f;
    tick(world, 5);
    dino.idleDuration = 5.f;
    tick(world, 40);

    AnimationComponent& anim = world.get_component<AnimationComponent>(dinoId);
    XCTAssertEqual(dino.lastOutcome, DinoInterruptOutcome::Failed);
    XCTAssertTrue(dino.outcomeThisCycle);
    XCTAssertEqual(dino.state, DinoBehaviorState::Idle);
    XCTAssertEqual(anim.currentClip, CharacterClipSlot::Idle);
}

- (void)test_incompletePerSpeciesClipTableFailsLoudly {
    bool loaded[(int)CharacterClipSlot::Count] = {};
    for (int i = 0; i < (int)CharacterClipSlot::Count; ++i) loaded[i] = true;
    loaded[(int)CharacterClipSlot::Jump] = false;

    bool threw = false;
    try {
        CharacterClipTable_validate_required(loaded, @"velociraptor-test");
    } catch (const std::runtime_error& ex) {
        threw = true;
        std::string message = ex.what();
        XCTAssertTrue(message.find("velociraptor-test") != std::string::npos);
        XCTAssertTrue(message.find("jump") != std::string::npos);
    }
    XCTAssertTrue(threw);
}

- (void)test_vertexColorShaderMathPreservesTextureAndEnablesWhiteFallbackColor {
    auto shade = [](float texR, float texG, float texB,
                    float vtxR, float vtxG, float vtxB,
                    float tintR, float tintG, float tintB,
                    float tintStrength,
                    float out[3]) {
        float baseR = texR * vtxR;
        float baseG = texG * vtxG;
        float baseB = texB * vtxB;
        out[0] = baseR * (1.f - tintStrength) + tintR * tintStrength;
        out[1] = baseG * (1.f - tintStrength) + tintG * tintStrength;
        out[2] = baseB * (1.f - tintStrength) + tintB * tintStrength;
    };

    float textured[3] = {};
    shade(0.25f, 0.50f, 0.75f, 1.f, 1.f, 1.f, 1.f, 0.f, 0.f, 0.f, textured);
    XCTAssertEqualWithAccuracy(textured[0], 0.25f, 0.0001f);
    XCTAssertEqualWithAccuracy(textured[1], 0.50f, 0.0001f);
    XCTAssertEqualWithAccuracy(textured[2], 0.75f, 0.0001f);

    float dino[3] = {};
    shade(1.f, 1.f, 1.f, 0.20f, 0.65f, 0.30f, 1.f, 0.f, 0.f, 0.f, dino);
    XCTAssertEqualWithAccuracy(dino[0], 0.20f, 0.0001f);
    XCTAssertEqualWithAccuracy(dino[1], 0.65f, 0.0001f);
    XCTAssertEqualWithAccuracy(dino[2], 0.30f, 0.0001f);
}

@end
