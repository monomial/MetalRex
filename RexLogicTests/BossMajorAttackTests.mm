#import <XCTest/XCTest.h>
#include "Simulation/World.h"

// The boss major attack is now a two-phase, chart-scripted QTE and the ONLY
// way to damage a boss (bosses are immune to normal fire and flee once every
// scripted QTE resolves). Tests drive the camera to the m2-test chart's
// major_attack event distances (27.5 / 29.5 / 31.5) and let the real trigger
// fire, rather than poking health like the old damage-based version did.

@interface BossMajorAttackTests : XCTestCase
@end

@implementation BossMajorAttackTests

static EntityID findTrex(World& world) {
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.has_component<DinoBehaviorComponent>(id)) continue;
        if (world.get_component<DinoBehaviorComponent>(id).species == DinoSpecies::Trex) return id;
    }
    return kInvalidEntity;
}

static void tick(World& world, int count) {
    for (int i = 0; i < count; ++i) world.update(1.f / 120.f, 1.f / 120.f);
}

// Positions the camera just before a scripted major_attack distance and ticks
// until that QTE arms. Boss auto-arrives (chart arrival is distance 26).
static bool runToMajorAttack(World& world, float chartDistance) {
    world.rail_camera().distance = chartDistance - 0.3f;
    for (int i = 0; i < 200; ++i) {
        tick(world, 1);
        if (world.major_attack_active()) return true;
    }
    return false;
}

// Arms a QTE and advances past any one-time Preview to the shootable Live phase.
static bool runToLiveQTE(World& world, float chartDistance) {
    if (!runToMajorAttack(world, chartDistance)) return false;
    for (int i = 0; i < 400 && world.major_attack().phase != MajorAttackPhase::Live; ++i) {
        tick(world, 1);
    }
    return world.major_attack().phase == MajorAttackPhase::Live;
}

static void endMajorAttack(World& world) {
    world.major_attack_mutable().phase = MajorAttackPhase::Inactive;
}

// Waits for point i to appear, aims player at its live position, fires once,
// then waits out the fire cooldown so the next shot is its own press.
static void fireAtLivePoint(World& world, int player, int i) {
    for (int t = 0; t < 400 && world.major_attack().points[i].appear <= 0.f; ++t) tick(world, 1);
    const BossMajorAttackPointState& p = world.major_attack().points[i];
    world.reticle(player).x = p.screenX;
    world.reticle(player).y = p.screenY;
    InputState fire = {};
    fire.fire = true;
    world.set_input(fire, player);
    tick(world, 1);
    world.set_input(InputState{}, player);
    tick(world, 30);
}

- (void)test_firstScriptedQTEArmsPreviewThenLive {
    World world;
    EntityID trexId = findTrex(world);
    XCTAssertNotEqual(trexId, kInvalidEntity);

    XCTAssertTrue(runToMajorAttack(world, 27.5f));
    const BossMajorAttackState& attack = world.major_attack();
    // First QTE of the fight opens with the one-time Preview portrait.
    XCTAssertEqual((int)attack.phase, (int)MajorAttackPhase::Preview);
    XCTAssertTrue(attack.showPortrait);
    XCTAssertEqual(attack.bossEntity, trexId);
    XCTAssertEqual((int)attack.species, (int)DinoSpecies::Trex);
    XCTAssertFalse(attack.isFinal); // two more scripted QTEs remain
    XCTAssertEqual(attack.hitCount, 0);

    // Preview runs its course, then the shootable Live phase begins with a
    // fresh countdown.
    for (int i = 0; i < 400 && world.major_attack().phase != MajorAttackPhase::Live; ++i) {
        tick(world, 1);
    }
    XCTAssertEqual((int)world.major_attack().phase, (int)MajorAttackPhase::Live);
    XCTAssertEqualWithAccuracy(world.major_attack().timeRemaining,
                               world.major_attack().countdownDuration, 0.2f);
}

- (void)test_secondScriptedQTESkipsPreview {
    World world;
    XCTAssertTrue(runToMajorAttack(world, 27.5f));
    XCTAssertEqual((int)world.major_attack().phase, (int)MajorAttackPhase::Preview);

    // Later QTEs in the same fight cut straight to the live targets.
    endMajorAttack(world);
    XCTAssertTrue(runToMajorAttack(world, 29.5f));
    XCTAssertEqual((int)world.major_attack().phase, (int)MajorAttackPhase::Live);
    XCTAssertFalse(world.major_attack().showPortrait);
}

- (void)test_liveTargetsAppearStaggeredAndAreDistinct {
    World world;
    XCTAssertTrue(runToLiveQTE(world, 27.5f));

    // The first target is up immediately; later ones are still closed at t~0.
    XCTAssertGreaterThan(world.major_attack().points[0].appear, 0.f);
    XCTAssertLessThanOrEqual(world.major_attack().points[3].appear, 0.f);

    // Let them all spawn in, then confirm they occupy distinct, on-screen spots.
    tick(world, 240);
    for (int i = 0; i < kBossMajorAttackPointCount; ++i) {
        const BossMajorAttackPointState& p = world.major_attack().points[i];
        XCTAssertGreaterThan(p.appear, 0.f);
        XCTAssertGreaterThanOrEqual(p.screenX, 0.f);
        XCTAssertLessThanOrEqual(p.screenX, 1.f);
    }
    XCTAssertNotEqualWithAccuracy(world.major_attack().points[0].screenX,
                                  world.major_attack().points[1].screenX, 0.0001f);
}

- (void)test_majorAttackSlowsCameraButNotAiming {
    World world;
    XCTAssertTrue(runToLiveQTE(world, 27.5f));

    float normalPerTick = world.rail_camera().speed * (1.f / 120.f);
    float distanceBefore = world.rail_camera().distance;
    tick(world, 60);
    float slowDelta = world.rail_camera().distance - distanceBefore;
    XCTAssertLessThan(slowDelta, normalPerTick * 60.f * 0.5f); // clearly slowed
    XCTAssertGreaterThan(slowDelta, 0.f);                      // but not frozen

    // Aiming stays full speed regardless of the slow-mo scene.
    world.reticle(0).x = 0.5f;
    InputState move = {};
    move.stickX = 1.f;
    world.set_input(move, 0);
    tick(world, 1);
    XCTAssertGreaterThan(world.reticle(0).x, 0.5f);
}

- (void)test_firingAtLivePointSetsHitAndScores {
    World world;
    XCTAssertTrue(runToLiveQTE(world, 27.5f));

    fireAtLivePoint(world, 0, 0);

    XCTAssertTrue(world.major_attack().points[0].hit);
    XCTAssertTrue(world.major_attack().hitMask & 0x1);
    XCTAssertEqual(world.major_attack().hitCount, 1);
    XCTAssertEqual(world.score(0).score, 40);

    ScorePopupEvent popups[kMaxScorePopupsPerFrame];
    int count = world.consume_score_popups(popups);
    XCTAssertEqual(count, 1);
    XCTAssertEqual(popups[0].points, 40);
}

- (void)test_perfectClearNoDamageBonusThenResumes {
    World world;
    XCTAssertTrue(runToLiveQTE(world, 27.5f));
    int healthBefore = world.player_health(0).health;

    for (int i = 0; i < kBossMajorAttackPointCount; ++i) fireAtLivePoint(world, 0, i);

    const BossMajorAttackState& attack = world.major_attack();
    XCTAssertEqual(attack.hitCount, 4);
    XCTAssertEqual((int)attack.phase, (int)MajorAttackPhase::Result);
    XCTAssertTrue(attack.wasPerfect);
    XCTAssertEqual(world.player_health(0).health, healthBefore); // no retaliation
    XCTAssertGreaterThanOrEqual(world.score(0).score, 250);      // 4x40 + 250 bonus

    // Prevent the NEXT scripted QTE (29.5) from re-arming as the camera
    // resumes — this test is only about this QTE resolving and timing snapping
    // back, not the next beat.
    world.set_next_chart_event_index(world.chart().events.size());

    // Result holds, then (this isn't the final QTE) normal timing resumes.
    tick(world, 300);
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
        XCTAssertTrue(runToLiveQTE(world, 27.5f));
        int attackDamage = world.get_component<DinoBehaviorComponent>(trexId).attackDamage;

        int hits = kBossMajorAttackPointCount - misses;
        for (int i = 0; i < hits; ++i) fireAtLivePoint(world, 0, i);

        int healthBefore = world.player_health(0).health;
        world.major_attack_mutable().timeRemaining = 0.f; // force timeout
        tick(world, 1);

        XCTAssertEqual((int)world.major_attack().phase, (int)MajorAttackPhase::Result);
        int expected = (int)((float)attackDamage * kMultiplier[misses - 1]);
        XCTAssertEqual(healthBefore - world.player_health(0).health, expected,
                       @"miss count %d", misses);
    }
}

- (void)test_totalFailureDamagesBothActivePlayers {
    World world;
    XCTAssertTrue(runToLiveQTE(world, 27.5f));
    XCTAssertTrue(world.reticle(0).active);
    XCTAssertTrue(world.reticle(1).active);

    int h0 = world.player_health(0).health;
    int h1 = world.player_health(1).health;
    world.major_attack_mutable().timeRemaining = 0.f; // 0/4, total failure
    tick(world, 1);

    XCTAssertLessThan(world.player_health(0).health, h0);
    XCTAssertLessThan(world.player_health(1).health, h1);
}

@end
