#import <XCTest/XCTest.h>
#include "Simulation/Systems/DinoBehaviorSystem.h"
#include "Simulation/BossMajorAttackPoints.h"
#include "Simulation/World.h"

@interface BossMajorAttackTests : XCTestCase
@end

@implementation BossMajorAttackTests

static EntityID findTrex(World& world) {
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.has_component<DinoBehaviorComponent>(id)) continue;
        if (world.get_component<DinoBehaviorComponent>(id).species == DinoSpecies::Trex) {
            return id;
        }
    }
    return kInvalidEntity;
}

static void tick(World& world, int count) {
    for (int i = 0; i < count; ++i) {
        world.update(1.f / 120.f, 1.f / 120.f);
    }
}

static void activateDino(World& world, EntityID id, DinoBehaviorState state) {
    DinoBehaviorComponent& dino = world.get_component<DinoBehaviorComponent>(id);
    dino.activeInEncounter = true;
    dino.state = state;
    dino.stateTime = 0.f;
    TargetComponent& target = world.target(dino.targetIndex);
    target.active = true;
    target.moving = true;
}

// Body-shoots the T-Rex up to (but not through) the phase-1 rage threshold,
// arming a major attack — same technique DinoBehaviorTests.mm's rage-phase
// tests use.
static void triggerPhaseOneMajorAttack(World& world, EntityID trexId) {
    DinoBehaviorComponent& trex = world.get_component<DinoBehaviorComponent>(trexId);
    activateDino(world, trexId, DinoBehaviorState::Approach);
    TargetComponent& target = world.target(trex.targetIndex);
    for (int i = 0; i < 14; ++i) {
        target.wasHit = true;
        target.lastHitWasWeakPoint = false;
        tick(world, 1);
    }
}

static void fireAtPoint(World& world, int player, const BossMajorAttackPoint& point) {
    float x, y;
    BossMajorAttackPoint_toViewport(point, &x, &y);
    world.reticle(player).x = x;
    world.reticle(player).y = y;
    InputState fire = {};
    fire.fire = true;
    world.set_input(fire, player);
    tick(world, 1);
    // Clear input and wait out the fire cooldown so the next call registers
    // as its own press rather than being cooldown-gated away.
    world.set_input(InputState{}, player);
    tick(world, 30);
}

- (void)test_ragePhaseEscalationArmsMajorAttack {
    World world;
    EntityID trexId = findTrex(world);
    XCTAssertNotEqual(trexId, kInvalidEntity);
    DinoBehaviorComponent& trex = world.get_component<DinoBehaviorComponent>(trexId);

    triggerPhaseOneMajorAttack(world, trexId);
    XCTAssertEqual(trex.ragePhase, 1);

    const BossMajorAttackState& attack = world.major_attack();
    XCTAssertTrue(attack.active);
    XCTAssertEqual(attack.bossEntity, trexId);
    XCTAssertEqual((int)attack.species, (int)DinoSpecies::Trex);
    XCTAssertEqual(attack.ragePhaseTrigger, 1);
    XCTAssertEqualWithAccuracy(attack.timeRemaining, attack.countdownDuration, 0.0001f);
    XCTAssertEqual(attack.hitMask, 0);
    XCTAssertEqual(attack.hitCount, 0);
    XCTAssertFalse(attack.resolved);
}

- (void)test_majorAttackSlowsCameraButNotAiming {
    World world;
    EntityID trexId = findTrex(world);
    triggerPhaseOneMajorAttack(world, trexId);
    XCTAssertTrue(world.major_attack_active());

    float normalDistancePerTick = world.rail_camera().speed * (1.f / 120.f);
    float distanceBefore = world.rail_camera().distance;
    tick(world, 60);
    float slowDelta = world.rail_camera().distance - distanceBefore;
    // Slow motion: nowhere near what 60 normal-speed ticks would cover, but
    // still moving (not a hard freeze).
    XCTAssertLessThan(slowDelta, normalDistancePerTick * 60.f * 0.5f);
    XCTAssertGreaterThan(slowDelta, 0.f);

    // Aiming stays at full, unscaled responsiveness regardless.
    world.reticle(0).x = 0.5f;
    InputState move = {};
    move.stickX = 1.f;
    world.set_input(move, 0);
    tick(world, 1);
    XCTAssertGreaterThan(world.reticle(0).x, 0.5f);
}

- (void)test_firingAtPointSetsHitMaskAndScores {
    World world;
    EntityID trexId = findTrex(world);
    triggerPhaseOneMajorAttack(world, trexId);
    XCTAssertTrue(world.major_attack_active());

    const BossMajorAttackPoint* points = BossMajorAttackPoints_for(DinoSpecies::Trex);
    float px, py;
    BossMajorAttackPoint_toViewport(points[0], &px, &py);
    fireAtPoint(world, 0, points[0]);

    XCTAssertTrue(world.major_attack().hitMask & 0x1);
    XCTAssertEqual(world.major_attack().hitCount, 1);
    XCTAssertEqual(world.score(0).score, 40);

    ScorePopupEvent popups[kMaxScorePopupsPerFrame];
    int count = world.consume_score_popups(popups);
    XCTAssertEqual(count, 1);
    XCTAssertEqual(popups[0].points, 40);
    XCTAssertEqualWithAccuracy(popups[0].screenX, px, 0.0001f);
    XCTAssertEqualWithAccuracy(popups[0].screenY, py, 0.0001f);
}

- (void)test_perfectClearResolvesWithNoDamageAndBonusThenResumes {
    World world;
    EntityID trexId = findTrex(world);
    triggerPhaseOneMajorAttack(world, trexId);
    XCTAssertTrue(world.major_attack_active());
    int healthBefore = world.player_health(0).health;

    const BossMajorAttackPoint* points = BossMajorAttackPoints_for(DinoSpecies::Trex);
    for (int i = 0; i < kBossMajorAttackPointCount; ++i) {
        fireAtPoint(world, 0, points[i]);
    }

    XCTAssertEqual(world.major_attack().hitCount, 4);
    XCTAssertTrue(world.major_attack().resolved);
    XCTAssertEqual(world.player_health(0).health, healthBefore);
    XCTAssertGreaterThanOrEqual(world.score(0).score, 250);

    // Still active through the result-hold window.
    XCTAssertTrue(world.major_attack_active());
    tick(world, 200); // > resultHoldRemaining (~1.2s)
    XCTAssertFalse(world.major_attack_active());

    float distanceBefore = world.rail_camera().distance;
    tick(world, 1);
    XCTAssertGreaterThan(world.rail_camera().distance, distanceBefore);
}

- (void)test_damageCurveIndexedByMissCount {
    static const float kMultiplier[4] = {0.5f, 0.75f, 1.0f, 1.5f}; // 1,2,3,4 misses
    for (int misses = 1; misses <= 4; ++misses) {
        World world;
        EntityID trexId = findTrex(world);
        DinoBehaviorComponent& trex = world.get_component<DinoBehaviorComponent>(trexId);
        triggerPhaseOneMajorAttack(world, trexId);
        XCTAssertTrue(world.major_attack_active());

        int hits = 4 - misses;
        const BossMajorAttackPoint* points = BossMajorAttackPoints_for(DinoSpecies::Trex);
        for (int i = 0; i < hits; ++i) {
            fireAtPoint(world, 0, points[i]);
        }

        int healthBefore = world.player_health(0).health;
        world.major_attack_mutable().timeRemaining = 0.f;
        tick(world, 1);

        XCTAssertTrue(world.major_attack().resolved);
        int expectedDamage = (int)((float)trex.attackDamage * kMultiplier[misses - 1]);
        XCTAssertEqual(healthBefore - world.player_health(0).health, expectedDamage,
                       @"miss count %d", misses);
    }
}

- (void)test_totalFailureDamagesBothActivePlayers {
    World world;
    EntityID trexId = findTrex(world);
    triggerPhaseOneMajorAttack(world, trexId);
    XCTAssertTrue(world.major_attack_active());
    XCTAssertTrue(world.reticle(0).active);
    XCTAssertTrue(world.reticle(1).active);

    int health0Before = world.player_health(0).health;
    int health1Before = world.player_health(1).health;
    world.major_attack_mutable().timeRemaining = 0.f;
    tick(world, 1);

    XCTAssertLessThan(world.player_health(0).health, health0Before);
    XCTAssertLessThan(world.player_health(1).health, health1Before);
}

- (void)test_firingAtBossBodyDuringPopupDoesNotRegisterNormalHit {
    World world;
    EntityID trexId = findTrex(world);
    DinoBehaviorComponent& trex = world.get_component<DinoBehaviorComponent>(trexId);
    triggerPhaseOneMajorAttack(world, trexId);
    XCTAssertTrue(world.major_attack_active());
    int healthBefore = trex.health;

    TargetComponent& target = world.target(trex.targetIndex);
    world.reticle(0).x = target.screenX;
    world.reticle(0).y = target.screenY;
    InputState fire = {};
    fire.fire = true;
    world.set_input(fire, 0);
    tick(world, 1);

    XCTAssertFalse(target.wasHit);
    XCTAssertEqual(trex.health, healthBefore);
}

@end
