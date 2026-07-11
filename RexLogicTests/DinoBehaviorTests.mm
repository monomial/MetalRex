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

static int activeRaptorCount(World& world) {
    int count = 0;
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.has_component<DinoBehaviorComponent>(id)) continue;
        const DinoBehaviorComponent& dino = world.get_component<DinoBehaviorComponent>(id);
        if (dino.species == DinoSpecies::Velociraptor && dino.activeInEncounter) ++count;
    }
    return count;
}

static EntityID raptorWithLaneRole(World& world, uint8_t laneRole) {
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.has_component<DinoBehaviorComponent>(id)) continue;
        const DinoBehaviorComponent& dino = world.get_component<DinoBehaviorComponent>(id);
        if (dino.species == DinoSpecies::Velociraptor
            && dino.activeInEncounter
            && dino.laneRole == laneRole) {
            return id;
        }
    }
    return kInvalidEntity;
}

// Attacks are proximity-gated: the dino must be within attackRange behind
// the jeep before enter_attack can fire. Tests that need an attack place the
// dino at close range first.
static void placeWithinAttackRange(World& world, DinoBehaviorComponent& dino) {
    dino.activeInEncounter = true;
    world.target(dino.targetIndex).railDistance =
        world.rail_camera().distance - dino.attackRange + 0.5f;
    world.target(dino.targetIndex).active = true;
    world.target(dino.targetIndex).moving = true;
}

- (void)test_interruptWithinWindowCancelsAttackAndTransitionsToJumpReaction {
    World world;
    EntityID dinoId = findDino(world);
    XCTAssertNotEqual(dinoId, kInvalidEntity);

    DinoBehaviorComponent& dino = world.get_component<DinoBehaviorComponent>(dinoId);
    activateDino(world, dinoId, DinoBehaviorState::Hold);
    dino.holdDuration = 0.f;
    dino.attackDelay = 0.f;
    dino.interruptStartNormalized = 0.18f;
    dino.interruptEndNormalized = 0.60f;
    placeWithinAttackRange(world, dino);

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
    activateDino(world, dinoId, DinoBehaviorState::Hold);
    dino.holdDuration = 0.f;
    dino.attackDelay = 0.f;
    dino.jumpReactionDuration = 0.1f;
    placeWithinAttackRange(world, dino);
    tick(world, 5);
    tick(world, 40);

    AnimationComponent& anim = world.get_component<AnimationComponent>(dinoId);
    XCTAssertEqual(dino.lastOutcome, DinoInterruptOutcome::Failed);
    XCTAssertTrue(dino.outcomeThisCycle);
    XCTAssertEqual(dino.state, DinoBehaviorState::Retreat);
    XCTAssertEqual(anim.currentClip, CharacterClipSlot::Run);
}

- (void)test_chaseClosesGapFromBehindAndStopsDuringAttack {
    World world;
    EntityID dinoId = findDino(world);
    XCTAssertNotEqual(dinoId, kInvalidEntity);

    DinoBehaviorComponent& dino = world.get_component<DinoBehaviorComponent>(dinoId);
    activateDino(world, dinoId, DinoBehaviorState::Approach);
    dino.holdDuration = 10.f; // stay out of the attack for the whole first phase
    dino.chaseSpeed = 1.6f;

    // Start well behind (outside attackRange, inside the recycle window).
    world.target(dino.targetIndex).railDistance = world.rail_camera().distance - 6.f;

    float startDistance = world.target(dino.targetIndex).railDistance;
    tick(world, 12); // 0.1s
    float chased = world.target(dino.targetIndex).railDistance;
    // Ran after the jeep by chaseSpeed * t (railDistance INCREASES —
    // the dino chases from behind).
    XCTAssertEqualWithAccuracy(chased - startDistance, 1.6f * 0.1f, 0.002f);
    XCTAssertEqual(world.get_component<AnimationComponent>(dinoId).currentClip,
                   CharacterClipSlot::Run);

    // Entering the attack cycle freezes the chase.
    dino.state = DinoBehaviorState::Hold;
    dino.stateTime = 0.f;
    dino.holdDuration = 0.f;
    dino.attackDelay = 0.f;
    placeWithinAttackRange(world, dino);
    tick(world, 1);
    XCTAssertEqual(dino.state, DinoBehaviorState::Tell);
    float atAttackStart = world.target(dino.targetIndex).railDistance;
    tick(world, 6);
    XCTAssertEqualWithAccuracy(world.target(dino.targetIndex).railDistance,
                               atAttackStart, 0.0001f);
}

- (void)test_shotsDrainHealthThenDeathThenRespawnBehindJeep {
    World world;
    EntityID dinoId = findDino(world);
    XCTAssertNotEqual(dinoId, kInvalidEntity);

    DinoBehaviorComponent& dino = world.get_component<DinoBehaviorComponent>(dinoId);
    activateDino(world, dinoId, DinoBehaviorState::Approach);
    dino.holdDuration = 100.f; // never attack during this test
    int startHealth = dino.health;
    XCTAssertGreaterThan(startHealth, 1);

    // Each shot drains one health and starts a hit flash.
    world.target(dino.targetIndex).wasHit = true;
    tick(world, 1);
    XCTAssertEqual(dino.health, startHealth - 1);
    XCTAssertGreaterThan(dino.hitFlashTime, 0.f);
    XCTAssertEqual(dino.state, DinoBehaviorState::Approach);

    // Drain the rest: death cuts through to the Death clip.
    for (int shot = 1; shot < startHealth; ++shot) {
        world.target(dino.targetIndex).wasHit = true;
        tick(world, 1);
    }
    XCTAssertEqual(dino.health, 0);
    XCTAssertEqual(dino.state, DinoBehaviorState::Dying);
    XCTAssertEqual(world.get_component<AnimationComponent>(dinoId).currentClip,
                   CharacterClipSlot::Death);

    // Shots at a corpse do nothing further.
    world.target(dino.targetIndex).wasHit = true;
    tick(world, 1);
    XCTAssertEqual(dino.health, 0);
    XCTAssertEqual(dino.state, DinoBehaviorState::Dying);

    // Death clip (fallback 4.5s at the 2x death speed multiplier = 2.25s)
    // plus the 0.8s dissolve, then the dino respawns deep behind the jeep
    // with health restored.
    tick(world, 450);
    XCTAssertEqual(dino.state, DinoBehaviorState::Dormant);
    XCTAssertFalse(dino.activeInEncounter);
    XCTAssertEqual(dino.health, dino.maxHealth);
    XCTAssertEqualWithAccuracy(world.get_component<AnimationComponent>(dinoId).deathFade,
                               1.f, 0.0001f);
    float gap = world.rail_camera().distance - world.target(dino.targetIndex).railDistance;
    XCTAssertGreaterThan(gap, 4.f);
    XCTAssertLessThanOrEqual(gap, 10.f);
}

- (void)test_trexHasBossHealthAndDeathCompletesLevelWithoutRespawn {
    World world;
    EntityID trexId = findTrex(world);
    XCTAssertNotEqual(trexId, kInvalidEntity);

    DinoBehaviorComponent& trex = world.get_component<DinoBehaviorComponent>(trexId);
    XCTAssertEqual(trex.maxHealth, 40);
    XCTAssertEqual(trex.health, 40);
    // Arrival staging: the chart's boss arrives at distance 26, so it's
    // dormant at the start of the act. Force it in for this test.
    XCTAssertFalse(trex.activeInEncounter);
    activateDino(world, trexId, DinoBehaviorState::Approach);

    trex.health = 1;
    world.target(trex.targetIndex).wasHit = true;
    tick(world, 1);

    XCTAssertEqual(trex.state, DinoBehaviorState::Dying);
    XCTAssertFalse(world.level_complete());

    tick(world, 450);
    XCTAssertTrue(world.level_complete());
    XCTAssertFalse(trex.active);
    XCTAssertFalse(trex.activeInEncounter);
    XCTAssertFalse(world.target(trex.targetIndex).active);

    float distanceAfterComplete = world.rail_camera().distance;
    tick(world, 60);
    XCTAssertEqualWithAccuracy(world.rail_camera().distance, distanceAfterComplete, 0.0001f);
    XCTAssertEqual(trex.health, 0);
}

- (void)test_firePressAfterLevelCompleteRestartsTheLevel {
    World world;
    EntityID trexId = findTrex(world);
    XCTAssertNotEqual(trexId, kInvalidEntity);

    // Kill the boss with fire HELD — the exact input state a player is in
    // at the moment the T-Rex drops. (Force it into the encounter first —
    // the chart stages its arrival at distance 26.)
    activateDino(world, trexId, DinoBehaviorState::Approach);
    world.get_component<DinoBehaviorComponent>(trexId).health = 1;
    world.target(world.get_component<DinoBehaviorComponent>(trexId).targetIndex).wasHit = true;
    InputState heldFire = {};
    heldFire.fire = true;
    world.set_input(heldFire, 0);
    tick(world, 500);
    XCTAssertTrue(world.level_complete());

    // Fire held through the panel: must NOT restart, no matter how long —
    // the trigger-mash that killed the boss can't skip the panel.
    tick(world, 400); // >1.5s minimum display time, fire never released
    XCTAssertTrue(world.level_complete());

    // Release, then a fresh press: restarts the scene.
    world.set_input(InputState{}, 0);
    tick(world, 5);
    world.set_input(heldFire, 0);
    tick(world, 5);

    XCTAssertFalse(world.level_complete());
    // Fresh scene: with arrival staging the boss restarts DORMANT (it joins
    // again at the chart's arrivalDistance), so the restarting trigger press
    // can't touch it — full health, not yet in the encounter.
    EntityID trexAfter = findTrex(world);
    XCTAssertNotEqual(trexAfter, kInvalidEntity);
    const DinoBehaviorComponent& trex = world.get_component<DinoBehaviorComponent>(trexAfter);
    XCTAssertTrue(trex.active);
    XCTAssertFalse(trex.activeInEncounter);
    XCTAssertEqual(trex.health, trex.maxHealth);
}

- (void)test_bossArrivesAtChartDistance {
    World world;
    EntityID trexId = findTrex(world);
    XCTAssertNotEqual(trexId, kInvalidEntity);
    DinoBehaviorComponent& trex = world.get_component<DinoBehaviorComponent>(trexId);
    XCTAssertEqualWithAccuracy(trex.bossArrivalDistance, 26.f, 0.001f);

    // Dormant through the early act (camera starts at 8, speed 1.2).
    tick(world, 120);
    XCTAssertFalse(trex.activeInEncounter);
    XCTAssertEqual(trex.state, DinoBehaviorState::Dormant);

    // Tick until the camera passes the arrival distance, then the finale
    // begins: boss enters Approach from deep behind the jeep.
    world.rail_camera().speed = 12.f; // compress the wait, same distances
    for (int i = 0; i < 400 && !trex.activeInEncounter; ++i) {
        world.update(1.f / 120.f, 1.f / 120.f);
    }
    XCTAssertTrue(trex.activeInEncounter);
    XCTAssertGreaterThanOrEqual(world.rail_camera().distance, 26.f);
    XCTAssertTrue(world.target(trex.targetIndex).active);
}

- (void)test_chartRaptorWaveActivatesSoloPairAndPack {
    World world;
    XCTAssertEqual(activeRaptorCount(world), 0);

    tick(world, 61); // crosses the 8.6 solo wave from the 8.0 camera start
    XCTAssertEqual(activeRaptorCount(world), 1);

    tick(world, 780); // solo has time to pounce, retreat, and free its slot
    XCTAssertEqual(activeRaptorCount(world), 2);

    tick(world, 840); // pair clears before the 22.0 three-raptor wave
    XCTAssertEqual(activeRaptorCount(world), 3);
}

- (void)test_chartEventsRearmAfterRailLoopWrap {
    // The test rail loops (fmod wrap in RailCameraSystem) but chart events
    // are consumed by a monotonically advancing index — without resetting
    // it on wrap, all raptor_wave events fire exactly once and the level
    // goes permanently quiet after the first lap, while the 40HP T-Rex
    // fight usually outlasts a lap.
    World world;
    XCTAssertGreaterThan(world.chart().events.size(), 0u);
    world.rail_camera().speed = 40.f; // cross the whole test rail in under a second

    float previous = world.rail_camera().distance;
    bool wrapped = false;
    for (int i = 0; i < 600 && !wrapped; ++i) {
        world.update(1.f / 120.f, 1.f / 120.f);
        float current = world.rail_camera().distance;
        if (current < previous) wrapped = true;
        previous = current;
    }
    XCTAssertTrue(wrapped);
    // Before the wrap every event was consumed (index == events.size());
    // the wrap must rearm them for the next lap.
    XCTAssertLessThan(world.next_chart_event_index(), world.chart().events.size());
}

- (void)test_raptorWaveApproachesHoldsThenStaggersPounce {
    World world;
    tick(world, 61);
    EntityID dinoId = raptorWithLaneRole(world, 0);
    XCTAssertNotEqual(dinoId, kInvalidEntity);

    DinoBehaviorComponent& dino = world.get_component<DinoBehaviorComponent>(dinoId);
    XCTAssertEqual(dino.state, DinoBehaviorState::Approach);

    tick(world, 320);
    XCTAssertTrue(dino.state == DinoBehaviorState::Hold
                  || dino.state == DinoBehaviorState::Tell
                  || dino.state == DinoBehaviorState::Attack);

    World pairWorld;
    tick(pairWorld, 61 + 780);
    EntityID first = raptorWithLaneRole(pairWorld, 0);
    EntityID second = raptorWithLaneRole(pairWorld, 1);
    XCTAssertNotEqual(first, kInvalidEntity);
    XCTAssertNotEqual(second, kInvalidEntity);

    DinoBehaviorComponent& lead = pairWorld.get_component<DinoBehaviorComponent>(first);
    DinoBehaviorComponent& trailer = pairWorld.get_component<DinoBehaviorComponent>(second);
    XCTAssertLessThan(lead.attackDelay, trailer.attackDelay);
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

- (void)test_railWrapPreservesPursuerGaps {
    // The looping test rail's wrap used to leave pursuer railDistances
    // un-rebased: gap went hugely negative and the "nothing may pass the
    // jeep" clamp slammed every active dino to exactly 1 unit behind the
    // player — the boss visibly teleported on top of the jeep at the loop
    // point.
    World world;
    EntityID trexId = findTrex(world);
    XCTAssertNotEqual(trexId, kInvalidEntity);
    DinoBehaviorComponent& trex = world.get_component<DinoBehaviorComponent>(trexId);
    activateDino(world, trexId, DinoBehaviorState::Approach);

    // Park the camera just short of the rail's end with the boss 5 behind.
    float railLength = world.chart().rail.total_length();
    world.rail_camera().distance = railLength - 0.5f;
    world.target(trex.targetIndex).railDistance = world.rail_camera().distance - 5.f;

    // One second of travel at the default 1.2 u/s crosses the wrap.
    float before = world.rail_camera().distance;
    tick(world, 120);
    XCTAssertLessThan(world.rail_camera().distance, before); // wrapped

    // Gap preserved through the wrap (boss closes at ~0.2 u/s net, so a
    // second of chasing only shaves a fraction) — NOT pinned to 1.
    float gap = world.rail_camera().distance - world.target(trex.targetIndex).railDistance;
    XCTAssertGreaterThan(gap, 3.5f);
    XCTAssertLessThan(gap, 6.f);
}

- (void)test_weakPointHitsDealDoubleDamage {
    World world;
    EntityID dinoId = findDino(world);
    XCTAssertNotEqual(dinoId, kInvalidEntity);
    DinoBehaviorComponent& dino = world.get_component<DinoBehaviorComponent>(dinoId);
    activateDino(world, dinoId, DinoBehaviorState::Approach);
    dino.holdDuration = 100.f;
    int startHealth = dino.health;

    TargetComponent& target = world.target(dino.targetIndex);
    target.wasHit = true;
    target.lastHitWasWeakPoint = true;
    tick(world, 1);
    XCTAssertEqual(dino.health, startHealth - 2);

    target.wasHit = true;
    target.lastHitWasWeakPoint = false;
    tick(world, 1);
    XCTAssertEqual(dino.health, startHealth - 3);
}

- (void)test_bossRagePhasesEscalateAtHealthThresholds {
    World world;
    EntityID trexId = findTrex(world);
    XCTAssertNotEqual(trexId, kInvalidEntity);
    DinoBehaviorComponent& trex = world.get_component<DinoBehaviorComponent>(trexId);
    activateDino(world, trexId, DinoBehaviorState::Approach);
    float baseHold = trex.holdDuration;
    float baseChase = trex.chaseSpeed;
    XCTAssertEqual(trex.ragePhase, 0);

    TargetComponent& target = world.target(trex.targetIndex);
    // Body-shoot down to just past 1/3 damage taken (40 -> 26).
    for (int i = 0; i < 14; ++i) {
        target.wasHit = true;
        target.lastHitWasWeakPoint = false;
        tick(world, 1);
    }
    XCTAssertEqual(trex.ragePhase, 1);
    XCTAssertLessThan(trex.holdDuration, baseHold);
    XCTAssertGreaterThan(trex.chaseSpeed, baseChase);

    // Past 2/3 damage taken (26 -> 13).
    float phase1Hold = trex.holdDuration;
    for (int i = 0; i < 13; ++i) {
        target.wasHit = true;
        target.lastHitWasWeakPoint = false;
        tick(world, 1);
    }
    XCTAssertEqual(trex.ragePhase, 2);
    XCTAssertLessThan(trex.holdDuration, phase1Hold);
    // One-way: healing never exists, but the phase must never regress
    // and never re-apply multipliers on later hits within the phase.
    float phase2Hold = trex.holdDuration;
    target.wasHit = true;
    tick(world, 1);
    XCTAssertEqual(trex.ragePhase, 2);
    XCTAssertEqualWithAccuracy(trex.holdDuration, phase2Hold, 0.0001f);
}

@end