#import <XCTest/XCTest.h>
#include "Simulation/Systems/DinoBehaviorSystem.h"
#include "Simulation/Systems/ReticleSystem.h"
#include "Simulation/Systems/ScoringSystem.h"
#include "Simulation/World.h"

@interface ScoringTests : XCTestCase
@end

@implementation ScoringTests

static EntityID findDino(World& world) {
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (world.has_component<DinoBehaviorComponent>(id)) return id;
    }
    return kInvalidEntity;
}

- (void)test_weakPointHitAwardsBonusInsteadOfBaseHit {
    World world;
    EntityID dinoId = findDino(world);
    XCTAssertNotEqual(dinoId, kInvalidEntity);

    DinoBehaviorComponent& dino = world.get_component<DinoBehaviorComponent>(dinoId);
    dino.idleDuration = 100.f;
    for (int i = 0; i < kM1MaxTargets; ++i) {
        world.target(i).active = false;
    }
    TargetComponent& target = world.target(dino.targetIndex);
    target.active = true;
    target.screenX = 0.42f;
    target.screenY = 0.38f;
    target.screenHalfW = 0.10f;
    target.screenHalfH = 0.12f;
    target.weakPointHalfW = 0.05f;
    target.weakPointOffsetY = target.screenHalfH * 0.65f;

    world.reticle(0).x = target.screenX;
    world.reticle(0).y = target.screenY + target.weakPointOffsetY;
    InputState fire = {};
    fire.fire = true;
    world.set_input(fire, 0);

    ReticleSystem_update(world, 1.f / 120.f);
    XCTAssertTrue(target.wasHit);
    XCTAssertTrue(target.lastHitWasWeakPoint);
    XCTAssertEqual(target.lastHitByPlayer, 0);

    DinoBehaviorSystem_update(world, 1.f / 120.f);
    ScoringSystem_update(world, 1.f / 120.f);

    const PlayerScoreState& score = world.score(0);
    XCTAssertEqual(score.score, 25);
    XCTAssertEqual(score.currentStreak, 1);
    XCTAssertEqual(score.bestStreak, 1);
    XCTAssertEqual(score.shotsHit, 1);
    XCTAssertEqual(score.shotsFired, 1);
    XCTAssertEqual(score.weakPointHits, 1);
    XCTAssertEqual(score.interruptSuccesses, 0);
}

- (void)test_interruptFailAndTellMissedResetThatPlayersStreak {
    World world;
    world.score(0).currentStreak = 4;
    world.score(0).bestStreak = 4;

    world.events().push_dino_score(0, DinoScoreEvent::InterruptFail, DinoSpecies::Velociraptor);
    ScoringSystem_update(world, 1.f / 120.f);
    XCTAssertEqual(world.score(0).currentStreak, 0);
    XCTAssertEqual(world.score(0).bestStreak, 4);

    world.score(0).currentStreak = 3;
    world.events().push_dino_score(0, DinoScoreEvent::TellMissed, DinoSpecies::Velociraptor);
    ScoringSystem_update(world, 1.f / 120.f);
    XCTAssertEqual(world.score(0).currentStreak, 0);
    XCTAssertEqual(world.score(0).bestStreak, 4);
}

- (void)test_playerOneMissDoesNotAffectPlayerTwoStreakOrAccuracy {
    World world;
    world.reticle(0).shotCount = 3;
    world.score(0).currentStreak = 2;
    world.score(0).shotsHit = 1;

    world.reticle(1).shotCount = 4;
    world.score(1).currentStreak = 5;
    world.score(1).bestStreak = 5;
    world.score(1).shotsHit = 2;

    world.events().push_dino_score(0, DinoScoreEvent::TellMissed, DinoSpecies::Trex);
    ScoringSystem_update(world, 1.f / 120.f);

    XCTAssertEqual(world.score(0).currentStreak, 0);
    XCTAssertEqual(world.score(0).shotsFired, 3);
    XCTAssertEqual(world.score(0).shotsHit, 1);

    XCTAssertEqual(world.score(1).currentStreak, 5);
    XCTAssertEqual(world.score(1).bestStreak, 5);
    XCTAssertEqual(world.score(1).shotsFired, 4);
    XCTAssertEqual(world.score(1).shotsHit, 2);
}

@end
