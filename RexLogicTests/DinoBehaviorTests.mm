#import <XCTest/XCTest.h>
#include "Assets/CharacterLoader.h"
#include "Simulation/Systems/DinoBehaviorSystem.h"
#include "Simulation/Systems/AnimationSystem.h"
#include "Simulation/Systems/ScreenShakeSystem.h"
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

static EntityID activateSingleEntryWave(World& world, RaptorArchetype archetype,
                                        int activePlayers, uint32_t seed, float holdSeconds = 2.f) {
    LevelChart chart = world.chart();
    chart.events.clear();
    ChartEvent event;
    event.distance = 0.f;
    event.type = "raptor_wave";
    event.raptorWave.valid = true;
    event.raptorWave.groupSize = 1;
    event.raptorWave.usesEntries = true;
    event.raptorWave.entries[0].archetype = archetype;
    event.raptorWave.entries[0].lane = 0.f;
    event.raptorWave.holdSeconds = holdSeconds;
    event.raptorWave.attackStaggerSeconds = 0.f;
    event.raptorWave.label = "test-wave";
    chart.events.push_back(event);
    world.replace_chart_for_tests(std::move(chart));
    for (int p = 0; p < kRexMaxPlayers; ++p) {
        world.reticle(p).active = p < activePlayers;
    }
    world.set_seed(seed);
    DinoBehaviorSystem_update(world, 1.f / 120.f);
    return raptorWithLaneRole(world, 0);
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

// Bosses take damage only through chart-scripted major-attack QTEs now, so
// tests drive the camera to a major_attack event distance and let the real
// trigger fire (the m2-test chart scripts QTEs at 27.5 / 29.5 / 31.5). Returns
// true once the QTE went active.
// A boss QTE now DEFERS while any raptor is still on-screen (consume_chart_events).
// Jumping the camera to a QTE distance back-fills every earlier scripted wave in
// one tick, so stand in for "the player wiped the wave" by dormanting the
// raptors each iteration — otherwise the deferred QTE never arms.
static void clearActiveRaptors(World& world) {
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.has_component<DinoBehaviorComponent>(id)) continue;
        DinoBehaviorComponent& dino = world.get_component<DinoBehaviorComponent>(id);
        if (dino.isBoss || dino.species != DinoSpecies::Velociraptor) continue;
        dino.activeInEncounter = false;
        dino.state = DinoBehaviorState::Dormant;
    }
}

static bool runToMajorAttack(World& world, float chartDistance) {
    // Jump the event cursor straight to the target QTE so earlier scripted
    // QTEs/waves don't fire first (the deferral would otherwise arm the first
    // one once its wave is cleared, not the one this test wants).
    const std::vector<ChartEvent>& events = world.chart().events;
    for (size_t i = 0; i < events.size(); ++i) {
        if (events[i].type == "major_attack"
            && fabsf(events[i].distance - chartDistance) < 0.01f) {
            world.set_next_chart_event_index(i);
            break;
        }
    }
    world.rail_camera().distance = chartDistance - 0.3f;
    for (int i = 0; i < 200; ++i) {
        clearActiveRaptors(world);
        world.update(1.f / 120.f, 1.f / 120.f);
        if (world.major_attack_active()) return true;
    }
    return false;
}

// Test shortcut: force the current QTE to end so the next scripted one can be
// reached without simulating a full 6s countdown. (Skips the resolve/flee
// bookkeeping — tests that care about those simulate the countdown for real.)
static void endMajorAttack(World& world) {
    world.major_attack_mutable().phase = MajorAttackPhase::Inactive;
}

// Isolate a real spawned wave from later chart events and camera wrapping.
static void isolateTellWorld(World& world) {
    world.set_next_chart_event_index(world.chart().events.size());
    world.rail_camera().speed = 0.f;
}

- (void)test_raptorTellFiresOnceWithFixedLeadThroughStrike {
    World world;
    EntityID id = activateSingleEntryWave(world, RaptorArchetype::Chase, 1, 0xC0FFEEu);
    isolateTellWorld(world);
    auto& dino = world.get_component<DinoBehaviorComponent>(id);
    int cueTick = -1, lungeTick = -1, total = 0;
    bool sawHold = false, sawTell = false;
    for (int i = 0; i < 1600 && dino.state != DinoBehaviorState::Dormant; ++i) {
        auto before = dino.state;
        tick(world, 1);
        int cues = world.consume_audio_cues().raptorTells;
        total += cues;
        if (cues) {
            XCTAssertEqual(cues, 1);
            XCTAssertEqual(before, DinoBehaviorState::Hold);
            XCTAssertEqual(cueTick, -1);
            cueTick = i;
        }
        sawHold |= dino.state == DinoBehaviorState::Hold;
        sawTell |= dino.state == DinoBehaviorState::Tell;
        if (before == DinoBehaviorState::Hold && dino.state == DinoBehaviorState::Tell) lungeTick = i;
    }
    XCTAssertTrue(sawHold);
    XCTAssertTrue(sawTell);
    XCTAssertEqual(total, 1);
    XCTAssertGreaterThanOrEqual(cueTick, 0);
    XCTAssertGreaterThan(lungeTick, cueTick);
    XCTAssertEqualWithAccuracy((lungeTick - cueTick) / 120.f, kTellLeadSeconds, 1.f / 120.f);
    XCTAssertEqual(world.player_health(0).health, 100 - dino.attackDamage);
    XCTAssertEqual(dino.state, DinoBehaviorState::Dormant);
    XCTAssertFalse(dino.tellCueFired); // enter_dormant rearms the recycled slot
}

- (void)test_shortArenaHoldsTellOnFirstHoldTickIncludingZeroHold {
    for (float hold : {0.f, 0.1f, 0.4f}) {
        World world;
        isolateTellWorld(world);
        XCTAssertTrue(DinoBehaviorSystem_spawn_arena_raptor(world, 1, 0.f, 7.f, hold, 0.f));
        EntityID id = findDino(world);
        auto& dino = world.get_component<DinoBehaviorComponent>(id);
        int total = 0;
        for (int i = 0; i < 600 && dino.state != DinoBehaviorState::Hold; ++i) {
            tick(world, 1);
            total += world.consume_audio_cues().raptorTells;
        }
        XCTAssertEqual(dino.state, DinoBehaviorState::Hold);
        XCTAssertEqual(total, 0);
        XCTAssertLessThan(dino.holdDuration + dino.attackDelay, kTellLeadSeconds);
        tick(world, 1);
        total += world.consume_audio_cues().raptorTells;
        XCTAssertEqual(total, 1);
        XCTAssertTrue(dino.tellCueFired);
        for (int i = 0; i < 180 && dino.state != DinoBehaviorState::Retreat; ++i) {
            tick(world, 1);
            total += world.consume_audio_cues().raptorTells;
        }
        XCTAssertEqual(dino.state, DinoBehaviorState::Retreat);
        XCTAssertEqual(total, 1);
    }
}

- (void)test_closeAmbushShortHoldTellsImmediatelyOnce {
    World world;
    EntityID id = activateSingleEntryWave(world, RaptorArchetype::CloseAmbush, 1, 42, 0.4f);
    isolateTellWorld(world);
    auto& dino = world.get_component<DinoBehaviorComponent>(id);
    for (int i = 0; i < 600 && dino.state != DinoBehaviorState::Hold; ++i) tick(world, 1);
    XCTAssertEqual(dino.state, DinoBehaviorState::Hold);
    XCTAssertEqualWithAccuracy(dino.holdDuration, 0.18f, 0.0001f);
    XCTAssertEqual(world.consume_audio_cues().raptorTells, 0);
    tick(world, 1);
    XCTAssertEqual(world.consume_audio_cues().raptorTells, 1);
    tick(world, 180);
    XCTAssertEqual(world.consume_audio_cues().raptorTells, 0);
}

- (void)test_bossArrivalAndLoomNeverTell {
    World world;
    isolateTellWorld(world);
    EntityID id = findTrex(world);
    auto& boss = world.get_component<DinoBehaviorComponent>(id);
    world.rail_camera().distance = boss.bossArrivalDistance;
    boss.attackRange = 3.f; // exact stopped-camera boundary avoids float subtraction drift
    boss.holdDuration = 0.f;
    boss.attackDelay = 0.f;
    bool sawApproach = false, sawHold = false;
    for (int i = 0; i < 1600; ++i) {
        tick(world, 1);
        sawApproach |= boss.state == DinoBehaviorState::Approach;
        sawHold |= boss.state == DinoBehaviorState::Hold;
        XCTAssertEqual(world.consume_audio_cues().raptorTells, 0);
        XCTAssertFalse(boss.tellCueFired);
    }
    XCTAssertTrue(sawApproach);
    XCTAssertTrue(sawHold);
}

- (void)test_arenaRetreatReapproachRearmsTell {
    World world;
    isolateTellWorld(world);
    XCTAssertTrue(DinoBehaviorSystem_spawn_arena_raptor(world, 1, 0.f, 8.f, 0.7f, 0.f));
    auto& dino = world.get_component<DinoBehaviorComponent>(findDino(world));
    int total = 0, holdEntries = 0;
    bool sawRetreat = false, sawReapproach = false;
    for (int i = 0; i < 1600 && total < 2; ++i) {
        auto before = dino.state;
        tick(world, 1);
        sawRetreat |= dino.state == DinoBehaviorState::Retreat;
        if (before == DinoBehaviorState::Retreat && dino.state == DinoBehaviorState::Approach) {
            sawReapproach = true;
            XCTAssertFalse(dino.tellCueFired);
            // Also independently exercise enter_hold's reset of a stale latch.
            dino.tellCueFired = true;
        }
        if (before == DinoBehaviorState::Approach && dino.state == DinoBehaviorState::Hold) {
            ++holdEntries;
            XCTAssertFalse(dino.tellCueFired);
        }
        int cues = world.consume_audio_cues().raptorTells;
        if (cues) XCTAssertEqual(before, DinoBehaviorState::Hold);
        total += cues;
    }
    XCTAssertTrue(sawRetreat);
    XCTAssertTrue(sawReapproach);
    XCTAssertEqual(holdEntries, 2);
    XCTAssertEqual(total, 2);
    XCTAssertGreaterThan(dino.health, 0);
}

- (void)test_raptorPutDownBeforeLeadNeverTells {
    World world;
    EntityID id = activateSingleEntryWave(world, RaptorArchetype::Chase, 1, 42);
    isolateTellWorld(world);
    auto& dino = world.get_component<DinoBehaviorComponent>(id);
    for (int i = 0; i < 800 && dino.state != DinoBehaviorState::Hold; ++i) tick(world, 1);
    XCTAssertEqual(dino.state, DinoBehaviorState::Hold);
    XCTAssertLessThan(dino.stateTime, dino.holdDuration + dino.attackDelay - kTellLeadSeconds);
    dino.health = 1;
    world.target(dino.targetIndex).wasHit = true;
    tick(world, 1);
    XCTAssertEqual(dino.state, DinoBehaviorState::PutDown);
    tick(world, 400);
    XCTAssertEqual(world.consume_audio_cues().raptorTells, 0);
    XCTAssertEqual(dino.state, DinoBehaviorState::Dormant);
}

- (void)test_simultaneousTellsRemainTruthfulAndDrainOnce {
    World world;
    isolateTellWorld(world);
    for (int i = 0; i < 3; ++i) {
        XCTAssertTrue(DinoBehaviorSystem_spawn_arena_raptor(world, 1, (i - 1) * 1.f, 5.f, 0.f, 0.f));
    }
    tick(world, 1); // all enter Hold
    XCTAssertEqual(world.audio_cues().raptorTells, 0);
    tick(world, 1); // all emit on the first Hold tick, before the zero-hold lunge
    XCTAssertEqual(world.audio_cues().raptorTells, 3); // host owns the two-voice cap
    world.audio_cues().shotsFired = 2;
    AudioCueCounts cues = world.consume_audio_cues();
    XCTAssertEqual(cues.raptorTells, 3);
    XCTAssertEqual(cues.shotsFired, 2);
    XCTAssertEqual(world.consume_audio_cues().raptorTells, 0);
    XCTAssertEqual(world.consume_audio_cues().shotsFired, 0);
    tick(world, 10);
    XCTAssertEqual(world.consume_audio_cues().raptorTells, 0);
}

- (void)test_packWaveTellSequenceIsDeterministicAndLeadIsStable {
    World a, b;
    LevelChart chart = a.chart();
    std::vector<ChartEvent> pack;
    for (auto event : chart.events) {
        if (event.type == "raptor_wave" && event.raptorWave.label == "pack-test") {
            event.distance = 0.f;
            pack.push_back(event);
        }
    }
    XCTAssertEqual(pack.size(), 1u);
    chart.events = pack;
    a.replace_chart_for_tests(chart);
    b.replace_chart_for_tests(chart);
    a.set_seed(0xC0FFEEu);
    b.set_seed(0xC0FFEEu);
    a.rail_camera().speed = b.rail_camera().speed = 0.f;
    std::vector<int> cueTick(a.entity_count(), -1);
    int total = 0, lunges = 0;
    for (int i = 0; i < 1800; ++i) {
        std::vector<DinoBehaviorState> before(a.entity_count(), DinoBehaviorState::Dormant);
        std::vector<bool> fired(a.entity_count(), false);
        for (EntityID id = 0; id < a.entity_count(); ++id) {
            if (!a.has_component<DinoBehaviorComponent>(id)) continue;
            const auto& d = a.get_component<DinoBehaviorComponent>(id);
            before[id] = d.state;
            fired[id] = d.tellCueFired;
        }
        tick(a, 1);
        tick(b, 1);
        int count = a.consume_audio_cues().raptorTells;
        XCTAssertEqual(count, b.consume_audio_cues().raptorTells);
        total += count;
        for (EntityID id = 0; id < a.entity_count(); ++id) {
            if (!a.has_component<DinoBehaviorComponent>(id)) continue;
            const auto& d = a.get_component<DinoBehaviorComponent>(id);
            if (!fired[id] && d.tellCueFired) cueTick[id] = i;
            if (before[id] == DinoBehaviorState::Hold && d.state == DinoBehaviorState::Tell) {
                ++lunges;
                XCTAssertGreaterThanOrEqual(cueTick[id], 0);
                float lead = (i - cueTick[id]) / 120.f;
                XCTAssertEqualWithAccuracy(lead, kTellLeadSeconds, 1.f / 120.f);
                NSLog(@"pack-test tell: lane=%u lead=%.6f game seconds", d.laneRole, lead);
            }
        }
    }
    XCTAssertEqual(total, 3);
    XCTAssertEqual(lunges, 3);
    XCTAssertEqual(activeRaptorCount(a), 0);
    XCTAssertEqual(activeRaptorCount(b), 0);
}

- (void)test_interruptWithinWindowPutsDownWithoutPlayerDamage {
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
    int playerHealth = world.player_health(0).health;
    world.target(dino.targetIndex).wasHit = true;
    world.target(dino.targetIndex).lastHitByPlayer = 0;
    tick(world, 1);

    AnimationComponent& anim = world.get_component<AnimationComponent>(dinoId);
    XCTAssertEqual(dino.lastOutcome, DinoInterruptOutcome::Succeeded);
    XCTAssertTrue(dino.outcomeThisCycle);
    XCTAssertEqual(dino.health, 0);
    XCTAssertEqual(dino.state, DinoBehaviorState::PutDown);
    XCTAssertEqual(anim.currentClip, CharacterClipSlot::Jump);
    XCTAssertEqual(world.player_health(0).health, playerHealth);
    XCTAssertEqual(world.particles().count, 14);
}

- (void)test_missLetsAttackClipCompleteNormally {
    World world;
    EntityID dinoId = findDino(world);
    XCTAssertNotEqual(dinoId, kInvalidEntity);

    DinoBehaviorComponent& dino = world.get_component<DinoBehaviorComponent>(dinoId);
    activateDino(world, dinoId, DinoBehaviorState::Hold);
    dino.holdDuration = 0.f;
    dino.attackDelay = 0.f;
    placeWithinAttackRange(world, dino);
    world.reticle(1).active = false;
    world.target(dino.targetIndex).baseLateralOffset = 0.f;
    world.target(dino.targetIndex).lateralOffset = 0.f;
    int playerHealth = world.player_health(0).health;
    tick(world, 5);
    tick(world, 40);

    AnimationComponent& anim = world.get_component<AnimationComponent>(dinoId);
    XCTAssertEqual(dino.lastOutcome, DinoInterruptOutcome::Failed);
    XCTAssertTrue(dino.outcomeThisCycle);
    XCTAssertEqual(dino.state, DinoBehaviorState::Departing);
    XCTAssertEqual(anim.currentClip, CharacterClipSlot::Run);
    XCTAssertEqual(world.player_health(0).health, playerHealth - dino.attackDamage);
}

- (void)test_windowHealthScalesDefaultChaseFromThreeAtOnePlayerToSixAtTwo {
    static constexpr uint32_t kSeed = 0x12345678u;
    World onePlayer;
    EntityID oneId = activateSingleEntryWave(onePlayer, RaptorArchetype::Chase, 1, kSeed);
    XCTAssertNotEqual(oneId, kInvalidEntity);
    XCTAssertEqual(onePlayer.get_component<DinoBehaviorComponent>(oneId).health, 3);

    World twoPlayers;
    EntityID twoId = activateSingleEntryWave(twoPlayers, RaptorArchetype::Chase, 2, kSeed);
    XCTAssertNotEqual(twoId, kInvalidEntity);
    XCTAssertEqual(twoPlayers.get_component<DinoBehaviorComponent>(twoId).health, 6);
}

- (void)test_closeAmbushHasOneHealthAndFairMinimumWindow {
    World world;
    EntityID id = activateSingleEntryWave(world, RaptorArchetype::CloseAmbush, 1, 0x12345678u);
    XCTAssertNotEqual(id, kInvalidEntity);
    const DinoBehaviorComponent& dino = world.get_component<DinoBehaviorComponent>(id);
    XCTAssertEqual(dino.health, 1);
    XCTAssertGreaterThanOrEqual(dino.shootingWindowSeconds, kMinFairWindowSeconds);
}

- (void)test_identicalSeedsProduceIdenticalGapHealthAndRateScale {
    World a;
    World b;
    EntityID aId = activateSingleEntryWave(a, RaptorArchetype::Chase, 2, 0xC0FFEEu);
    EntityID bId = activateSingleEntryWave(b, RaptorArchetype::Chase, 2, 0xC0FFEEu);
    const DinoBehaviorComponent& da = a.get_component<DinoBehaviorComponent>(aId);
    const DinoBehaviorComponent& db = b.get_component<DinoBehaviorComponent>(bId);
    XCTAssertEqualWithAccuracy(da.spawnGap, db.spawnGap, 0.000001f);
    XCTAssertEqual(da.health, db.health);
    XCTAssertEqualWithAccuracy(a.get_component<AnimationComponent>(aId).rateScale,
                               b.get_component<AnimationComponent>(bId).rateScale,
                               0.000001f);
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

- (void)test_shotsDrainHealthThenKidFriendlyPutDownReturnsDormant {
    World world;
    EntityID dinoId = findDino(world);
    XCTAssertNotEqual(dinoId, kInvalidEntity);

    DinoBehaviorComponent& dino = world.get_component<DinoBehaviorComponent>(dinoId);
    world.set_next_chart_event_index(world.chart().events.size());
    world.rail_camera().speed = 0.f;
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

    // Drain the rest: put-down cuts through to the Jump recoil, never Death.
    for (int shot = 1; shot < startHealth; ++shot) {
        world.target(dino.targetIndex).wasHit = true;
        tick(world, 1);
    }
    XCTAssertEqual(dino.health, 0);
    XCTAssertEqual(dino.state, DinoBehaviorState::PutDown);
    XCTAssertEqual(world.get_component<AnimationComponent>(dinoId).currentClip,
                   CharacterClipSlot::Jump);

    // Shots at a corpse do nothing further.
    world.target(dino.targetIndex).wasHit = true;
    tick(world, 1);
    XCTAssertEqual(dino.health, 0);
    XCTAssertEqual(dino.state, DinoBehaviorState::PutDown);
    XCTAssertNotEqual(world.get_component<AnimationComponent>(dinoId).currentClip,
                      CharacterClipSlot::Death);
    XCTAssertNotEqual(world.get_component<AnimationComponent>(dinoId).requestedClip,
                      CharacterClipSlot::Death);

    // The recoil dissolves in ~0.4s, then the fixed slot returns dormant.
    tick(world, 60);
    XCTAssertEqual(dino.state, DinoBehaviorState::Dormant);
    XCTAssertFalse(dino.activeInEncounter);
    XCTAssertEqual(dino.health, 0);
}

- (void)test_bossIsImmuneToNormalFire {
    // Jurassic Park model: normal fire can't damage a boss — only the QTE can.
    // Body-shooting the boss must never drain health or push it toward death.
    World world;
    EntityID trexId = findTrex(world);
    XCTAssertNotEqual(trexId, kInvalidEntity);
    DinoBehaviorComponent& trex = world.get_component<DinoBehaviorComponent>(trexId);
    activateDino(world, trexId, DinoBehaviorState::Approach);
    trex.holdDuration = 100.f; // don't let it wander into an attack cycle
    int startHealth = trex.health;

    for (int i = 0; i < 60; ++i) {
        world.target(trex.targetIndex).wasHit = true;
        world.target(trex.targetIndex).lastHitWasWeakPoint = (i % 2 == 0);
        tick(world, 1);
    }

    XCTAssertEqual(trex.health, startHealth); // untouched by fire
    XCTAssertNotEqual(trex.state, DinoBehaviorState::PutDown);
    XCTAssertFalse(world.level_complete());
    // The hit still flashes (it reads as a hit, just deals no damage).
    XCTAssertGreaterThan(trex.hitFlashTime, 0.f);
}

- (void)test_finalScriptedQTEMakesBossFleeThenEntersArena {
    // The boss flees (never dies) once the LAST scripted QTE resolves. With the
    // m2-test chart's post-boss arena, the flee hands off to the "stand your
    // ground" holdout (camera stops, arena active) rather than completing the
    // level — the arena completes it later (see ArenaTests).
    World world;
    XCTAssertTrue(runToMajorAttack(world, 31.5f));
    // Advance to the Live phase (a first-QTE-of-fight Preview may run first).
    for (int i = 0; i < 400 && world.major_attack().phase != MajorAttackPhase::Live; ++i) {
        tick(world, 1);
    }
    XCTAssertEqual((int)world.major_attack().phase, (int)MajorAttackPhase::Live);
    XCTAssertTrue(world.major_attack().isFinal);
    XCTAssertFalse(world.arena_active());

    // Let the countdown expire, the result hold pass, and the flee window run
    // out — real-time systems keep ticking, so ~9s of ticks covers it.
    for (int i = 0; i < 1200 && !world.arena_active(); ++i) {
        tick(world, 1);
    }
    XCTAssertTrue(world.arena_active());
    XCTAssertFalse(world.level_complete());          // holdout begins, not done
    XCTAssertFalse(world.major_attack_active());
    XCTAssertEqualWithAccuracy(world.rail_camera().speed, 0.f, 0.0001f);
}

- (void)test_firePressAfterLevelCompleteRestartsTheLevel {
    World world;
    EntityID trexId = findTrex(world);
    XCTAssertNotEqual(trexId, kInvalidEntity);

    // Reach LEVEL COMPLETE the way the boss fight now ends (it flees once the
    // fight is won). How we got here isn't what's under test — the play-again
    // gate is — so complete the level directly, with fire HELD (the input a
    // player is in at the winning moment).
    InputState heldFire = {};
    heldFire.fire = true;
    world.set_input(heldFire, 0);
    world.complete_level();
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
    // Consume past all chart events so jumping the camera near the rail's end
    // doesn't arm a scripted major-attack QTE (which would slow-mo the camera
    // and prevent the wrap this test is about).
    world.set_next_chart_event_index(world.chart().events.size());

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

// Rage escalation is now driven by each chart-scripted major attack (the boss
// takes no fire damage, so the old damage-taken thresholds can't fire): each
// QTE shortens the hold, quickens the chase, and bumps the tint phase.
- (void)test_bossRagePhaseEscalatesEachScriptedMajorAttack {
    World world;
    EntityID trexId = findTrex(world);
    XCTAssertNotEqual(trexId, kInvalidEntity);
    DinoBehaviorComponent& trex = world.get_component<DinoBehaviorComponent>(trexId);
    float baseHold = trex.holdDuration;
    float baseChase = trex.chaseSpeed;
    XCTAssertEqual(trex.ragePhase, 0);

    // First scripted QTE (chart distance 27.5) -> phase 1.
    XCTAssertTrue(runToMajorAttack(world, 27.5f));
    XCTAssertEqual(trex.ragePhase, 1);
    XCTAssertLessThan(trex.holdDuration, baseHold);
    XCTAssertGreaterThan(trex.chaseSpeed, baseChase);
    float phase1Hold = trex.holdDuration;

    // Second scripted QTE (29.5) -> phase 2.
    endMajorAttack(world);
    XCTAssertTrue(runToMajorAttack(world, 29.5f));
    XCTAssertEqual(trex.ragePhase, 2);
    XCTAssertLessThan(trex.holdDuration, phase1Hold);

    // Phase is capped at 2 — a third QTE must not escalate stats further.
    float phase2Hold = trex.holdDuration;
    endMajorAttack(world);
    XCTAssertTrue(runToMajorAttack(world, 31.5f));
    XCTAssertEqual(trex.ragePhase, 2);
    XCTAssertEqualWithAccuracy(trex.holdDuration, phase2Hold, 0.0001f);
}

// A T-Rex QTE must not pop while a raptor wave is still on-screen: the event
// stays parked until the field is clear, then fires the instant it is.
- (void)test_majorAttackDefersUntilRaptorsCleared {
    World world;
    EntityID trexId = findTrex(world);
    XCTAssertNotEqual(trexId, kInvalidEntity);
    activateDino(world, trexId, DinoBehaviorState::Approach); // boss in the fight

    // Park the event cursor on the first scripted major_attack, camera just
    // past its distance so it is due this tick.
    const std::vector<ChartEvent>& events = world.chart().events;
    size_t maIndex = events.size();
    for (size_t i = 0; i < events.size(); ++i) {
        if (events[i].type == "major_attack") { maIndex = i; break; }
    }
    XCTAssertLessThan(maIndex, events.size());
    world.set_next_chart_event_index(maIndex);
    world.rail_camera().distance = events[maIndex].distance + 0.05f;

    // A raptor still on the field -> the QTE stays deferred, cursor parked.
    EntityID raptorId = findDino(world); // slot-0 velociraptor (spawned first)
    XCTAssertNotEqual(raptorId, trexId);
    activateDino(world, raptorId, DinoBehaviorState::Approach);
    DinoBehaviorSystem_update(world, 1.f / 120.f);
    XCTAssertFalse(world.major_attack_active());
    XCTAssertEqual(world.next_chart_event_index(), maIndex);

    // Clear the raptor -> the deferred QTE fires and the cursor advances.
    world.get_component<DinoBehaviorComponent>(raptorId).activeInEncounter = false;
    DinoBehaviorSystem_update(world, 1.f / 120.f);
    XCTAssertTrue(world.major_attack_active());
    XCTAssertGreaterThan(world.next_chart_event_index(), maIndex);
}

// Jurassic Park model: the boss deals NO contact damage during the chase — its
// only attack is the scripted slow-motion QTE. Even parked in range with a zero
// hold, it must never enter the Tell/Attack melee cycle or drain player health.
- (void)test_bossNeverMeleesDuringChase {
    World world;
    EntityID trexId = findTrex(world);
    XCTAssertNotEqual(trexId, kInvalidEntity);
    DinoBehaviorComponent& trex = world.get_component<DinoBehaviorComponent>(trexId);
    // Isolate the boss: consume past every chart event so no raptor wave (which
    // could damage the player) and no QTE (which could, via a miss) interferes.
    world.set_next_chart_event_index(world.chart().events.size());
    activateDino(world, trexId, DinoBehaviorState::Hold);
    trex.holdDuration = 0.f;   // would attack immediately if it were allowed to
    trex.attackDelay = 0.f;
    placeWithinAttackRange(world, trex);
    int startHealth = world.player_health(0).health;

    for (int i = 0; i < 600; ++i) { // 5s — past many would-be attack cycles
        tick(world, 1);
        XCTAssertNotEqual((int)trex.state, (int)DinoBehaviorState::Tell);
        XCTAssertNotEqual((int)trex.state, (int)DinoBehaviorState::Attack);
    }
    XCTAssertEqual(world.player_health(0).health, startHealth);
    XCTAssertFalse(world.major_attack_active());
}

- (void)test_scriptedMajorAttackTriggersScreenShake {
    World world;
    // ScreenShakeSystem is deliberately global module state ("one camera,
    // one shake" — see its header), so a prior test in this same xctest
    // process can leave a nonzero magnitude behind. Drain it with an
    // oversized physicalDt before asserting so this test's result reflects
    // only the trigger below, not leftover state.
    ScreenShakeSystem_update(world, 10.f);
    XCTAssertEqual(simd_length(ScreenShakeSystem_offset(world)), 0.f);

    // Reaching the first scripted QTE triggers a shake as it arms.
    XCTAssertTrue(runToMajorAttack(world, 27.5f));
    tick(world, 1); // let the freshly triggered magnitude decay into an offset
    XCTAssertGreaterThan(simd_length(ScreenShakeSystem_offset(world)), 0.f);
}

@end
