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
    dino.activeInEncounter = true;
    dino.state = DinoBehaviorState::Approach;
    dino.holdDuration = 100.f;
    for (int i = 0; i < kM1MaxTargets; ++i) {
        world.target(i).active = false;
    }
    TargetComponent& target = world.target(dino.targetIndex);
    target.active = true;
    target.moving = true;
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


- (void)test_hitPushesScorePopupAtTargetPositionThenClears {
    World world;
    world.events().push_dino_score(1, DinoScoreEvent::WeakPointHit, DinoSpecies::Trex, 0.65f, 0.30f);
    ScoringSystem_update(world, 1.f / 120.f);

    ScorePopupEvent popups[kMaxScorePopupsPerFrame];
    int count = world.consume_score_popups(popups);
    XCTAssertEqual(count, 1);
    XCTAssertEqual(popups[0].player, 1);
    XCTAssertEqual(popups[0].points, 25);
    XCTAssertEqualWithAccuracy(popups[0].screenX, 0.65f, 0.0001f);
    XCTAssertEqualWithAccuracy(popups[0].screenY, 0.30f, 0.0001f);

    // Consuming drains the buffer; a missed shot pushes nothing new.
    XCTAssertEqual(world.consume_score_popups(popups), 0);
    world.events().push_dino_score(1, DinoScoreEvent::TellMissed, DinoSpecies::Trex);
    ScoringSystem_update(world, 1.f / 120.f);
    XCTAssertEqual(world.consume_score_popups(popups), 0);
}

- (void)test_letterGradeBoundaries {
    PlayerScoreState score = {};
    score.shotsFired = 100;

    // S demands both high accuracy AND real interrupt play.
    score.shotsHit = 80; score.interruptSuccesses = 3;
    XCTAssertEqual(ScoringSystem_letter_grade(score), 'S');
    score.interruptSuccesses = 2;
    XCTAssertEqual(ScoringSystem_letter_grade(score), 'A'); // accuracy alone caps at A

    score.interruptSuccesses = 0;
    score.shotsHit = 65; XCTAssertEqual(ScoringSystem_letter_grade(score), 'A');
    score.shotsHit = 64; XCTAssertEqual(ScoringSystem_letter_grade(score), 'B');
    score.shotsHit = 45; XCTAssertEqual(ScoringSystem_letter_grade(score), 'B');
    score.shotsHit = 44; XCTAssertEqual(ScoringSystem_letter_grade(score), 'C');
    score.shotsHit = 25; XCTAssertEqual(ScoringSystem_letter_grade(score), 'C');
    score.shotsHit = 24; XCTAssertEqual(ScoringSystem_letter_grade(score), 'D');

    // Zero shots fired must not divide by zero; it's a D.
    PlayerScoreState idle = {};
    XCTAssertEqual(ScoringSystem_letter_grade(idle), 'D');
}

@end
