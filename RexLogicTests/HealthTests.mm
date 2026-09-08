#import <XCTest/XCTest.h>
#include "Simulation/Systems/DinoBehaviorSystem.h"
#include "Simulation/World.h"
#include "Simulation/Systems/ScreenShakeSystem.h"

@interface HealthTests : XCTestCase
@end

@implementation HealthTests

static EntityID findDino(World& world) {
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (world.has_component<DinoBehaviorComponent>(id)) return id;
    }
    return kInvalidEntity;
}

static void tick(World& world, int count) {
    for (int i = 0; i < count; ++i) {
        world.update(1.f / 120.f);
    }
}

static void placeWithinAttackRange(World& world, DinoBehaviorComponent& dino) {
    TargetComponent& target = world.target(dino.targetIndex);
    dino.activeInEncounter = true;
    dino.state = DinoBehaviorState::Hold;
    dino.stateTime = 0.f;
    dino.holdDuration = 0.f;
    dino.attackDelay = 0.f;
    target.railDistance = world.rail_camera().distance - dino.attackRange + 0.5f;
    target.active = true;
    target.moving = true;
    // Center the lateral position rather than leaving whatever spawn-time
    // spread this target's raptor slot happens to be tuned to: DinoBehavior
    // routes a landed attack's damage to whichever player's reticle is
    // nearest the target's screen position (nearest_damage_target_player),
    // and this test wants that to unambiguously be player 0 (reticle x=0.5)
    // rather than depending on how wide the raptor pack's lateral spread is
    // configured this week.
    target.baseLateralOffset = 0.f;
    target.lateralOffset = 0.f;
}

// Mirrors DinoBehaviorTests' test_missLetsAttackClipCompleteNormally tick
// counts (known to carry an Attack clip through to clipDone) and additionally
// checks that a landed (unopposed) attack actually costs player 0 health.
- (void)test_dinoAttackLandingUnopposedDamagesPlayer {
    World world;
    EntityID dinoId = findDino(world);
    XCTAssertNotEqual(dinoId, kInvalidEntity);

    DinoBehaviorComponent& dino = world.get_component<DinoBehaviorComponent>(dinoId);
    placeWithinAttackRange(world, dino);
    int startHealth = world.player_health(0).health;

    tick(world, 5);
    tick(world, 40);

    XCTAssertEqual(dino.lastOutcome, DinoInterruptOutcome::Failed);
    XCTAssertEqual(world.player_health(0).health, startHealth - dino.attackDamage);
    XCTAssertEqual(dino.state, DinoBehaviorState::Departing);
    XCTAssertFalse(world.player_health(0).sittingOut);
}

- (void)test_damagePlayerHonorsPostHitInvulnerabilityWindow {
    World world;
    int startHealth = world.player_health(0).health;

    world.damage_player(0, 20);
    XCTAssertEqual(world.player_health(0).health, startHealth - 20);

    // A second hit landing right after the first must not also connect —
    // otherwise several dinos finishing an attack in the same moment could
    // stack into an instant, unavoidable death.
    world.damage_player(0, 20);
    XCTAssertEqual(world.player_health(0).health, startHealth - 20);
}

- (void)test_healthReachingZeroEntersGameOverAndFreezesRail {
    World world;
    float distanceBefore = world.rail_camera().distance;

    world.damage_player(0, 1000);
    XCTAssertTrue(world.player_health(0).sittingOut);
    XCTAssertEqual(world.player_health(0).health, 0);

    // Player 0 is the only active reticle by default in this scenario? No —
    // reset_m1_scene activates both P1 and P2, so sitting out P1 alone would
    // NOT freeze the rail (P2 is still in). Deactivate P2 first so this test
    // exercises the true "everyone is out" freeze condition.
    world.reticle(1).active = false;

    tick(world, 60);
    XCTAssertEqualWithAccuracy(world.rail_camera().distance, distanceBefore, 0.0001f);
}

- (void)test_continuePressResetsHealthAndUnfreezesRail {
    World world;
    world.reticle(1).active = false; // isolate to a 1P scenario
    world.damage_player(0, 1000);
    XCTAssertTrue(world.player_health(0).sittingOut);

    InputState input = {};
    input.fire = true;
    world.set_input(input, 0); // player 0's own fire press "inserts the coin"

    tick(world, 1);
    XCTAssertFalse(world.player_health(0).sittingOut);
    XCTAssertEqual(world.player_health(0).health, world.player_health(0).maxHealth);

    float distanceAfterContinue = world.rail_camera().distance;
    tick(world, 10);
    XCTAssertGreaterThan(world.rail_camera().distance, distanceAfterContinue);
}

// Premise 8: "a depleted player sits out (spectates, reticle hidden) while
// their partner continues solo." P1 depleted must not freeze P2's run, and
// must not show the shared GAME OVER panel condition.
- (void)test_onePlayerDepletedInTwoPlayerLetsPartnerContinue {
    World world;
    XCTAssertTrue(world.reticle(0).active);
    XCTAssertTrue(world.reticle(1).active); // 2P is active by default

    world.damage_player(0, 1000);
    XCTAssertTrue(world.player_health(0).sittingOut);
    XCTAssertFalse(world.player_health(1).sittingOut);
    XCTAssertTrue(world.any_player_active_and_not_sitting_out());

    float distanceBefore = world.rail_camera().distance;
    tick(world, 60);
    XCTAssertGreaterThan(world.rail_camera().distance, distanceBefore);

    // P1's stick input must not move their now-hidden reticle (fire is
    // deliberately excluded here — that's the revive input, tested by
    // test_continuePressResetsHealthAndUnfreezesRail and the simultaneous-
    // depletion test below, not a "does aiming still work" case).
    InputState input = {};
    input.stickX = 1.f;
    world.set_input(input, 0);
    float p1XBefore = world.reticle(0).x;
    tick(world, 1);
    XCTAssertEqual(world.reticle(0).x, p1XBefore);
}

// Both players depleted in the same tick: both sit out, the shared "everyone
// is out" condition goes true (freezing rail/dinos — covered by
// test_healthReachingZeroEntersGameOverAndFreezesRail for the 1P case), and
// either player's own fire press revives only themselves, not their partner.
- (void)test_bothPlayersDepletedSimultaneouslyThenEitherContinuesAlone {
    World world;
    world.damage_player(0, 1000);
    world.damage_player(1, 1000);
    XCTAssertTrue(world.player_health(0).sittingOut);
    XCTAssertTrue(world.player_health(1).sittingOut);
    XCTAssertFalse(world.any_player_active_and_not_sitting_out());

    InputState fire = {};
    fire.fire = true;
    world.set_input(fire, 1); // only P2 presses fire

    tick(world, 1);
    XCTAssertTrue(world.player_health(0).sittingOut);  // P1 still out
    XCTAssertFalse(world.player_health(1).sittingOut); // P2 revived themselves
    XCTAssertTrue(world.any_player_active_and_not_sitting_out());
}


- (void)test_hurtCuesOnlyForLandedHitsAndDrainOnce {
    World world;
    ScreenShakeSystem_update(world, 10.f);
    world.damage_player(0, 20);
    XCTAssertEqual(world.player_health(0).hitCount, 1u);
    XCTAssertEqual(world.consume_audio_cues().playerHurts, 1);
    XCTAssertEqual(world.consume_audio_cues().playerHurts, 0);
    ScreenShakeSystem_update(world, 1.f / 120.f);
    XCTAssertGreaterThan(simd_length(ScreenShakeSystem_offset(world)), 0.f);

    // A grace-period no-op must produce no sound, flash, shake, or rumble.
    ScreenShakeSystem_update(world, 10.f);
    world.player_health(0).hitFlashTime = 0.f;
    world.damage_player(0, 20);
    XCTAssertEqual(world.player_health(0).health, 80);
    XCTAssertEqual(world.player_health(0).hitCount, 1u);
    XCTAssertEqual(world.consume_audio_cues().playerHurts, 0);
    XCTAssertEqual(world.player_health(0).hitFlashTime, 0.f);
    ScreenShakeSystem_update(world, 1.f / 120.f);
    XCTAssertEqual(simd_length(ScreenShakeSystem_offset(world)), 0.f);

    world.player_health(0).invulnTime = 0.f;
    world.damage_player(0, 20);
    XCTAssertEqual(world.player_health(0).hitCount, 2u);
    XCTAssertEqual(world.consume_audio_cues().playerHurts, 1);

    ScreenShakeSystem_update(world, 10.f);
    world.player_health(0).sittingOut = true;
    world.player_health(0).invulnTime = 0.f; // isolate sittingOut gate
    world.player_health(0).hitFlashTime = 0.f;
    world.damage_player(0, 20);
    XCTAssertEqual(world.player_health(0).health, 60);
    XCTAssertEqual(world.player_health(0).hitCount, 2u);
    XCTAssertEqual(world.consume_audio_cues().playerHurts, 0);
    XCTAssertEqual(world.player_health(0).hitFlashTime, 0.f);
    ScreenShakeSystem_update(world, 1.f / 120.f);
    XCTAssertEqual(simd_length(ScreenShakeSystem_offset(world)), 0.f);
}

- (void)test_twoAttacksOnSameTickEmitOneHurt {
    World world;
    world.set_next_chart_event_index(world.chart().events.size());
    world.reticle(1).active = false;
    int armed = 0;
    for (EntityID id = 0; id < world.entity_count() && armed < 2; ++id) {
        if (!world.has_component<DinoBehaviorComponent>(id)) continue;
        auto& dino = world.get_component<DinoBehaviorComponent>(id);
        if (dino.isBoss) continue;
        placeWithinAttackRange(world, dino);
        dino.state = DinoBehaviorState::Attack;
        auto& anim = world.get_component<AnimationComponent>(id);
        anim.currentClip = CharacterClipSlot::Attack;
        anim.clipDone = true;
        ++armed;
    }
    XCTAssertEqual(armed, 2);
    DinoBehaviorSystem_update(world, 1.f / 120.f);
    XCTAssertEqual(world.consume_audio_cues().playerHurts, 1);
    XCTAssertEqual(world.player_health(0).hitCount, 1u);
    XCTAssertEqual(world.player_health(1).hitCount, 0u);
}

- (void)test_playerTwoHurtDoesNotRumblePlayerOneAndRestartClearsCounts {
    World world;
    world.damage_player(1, 20);
    XCTAssertEqual(world.player_health(0).hitCount, 0u);
    XCTAssertEqual(world.player_health(1).hitCount, 1u);
    XCTAssertEqual(world.consume_audio_cues().playerHurts, 1);
    world.enter_title();
    XCTAssertEqual(world.player_health(1).hitCount, 0u);
    XCTAssertEqual(world.consume_audio_cues().playerHurts, 0);
}

- (void)test_legibilitySequencesAreDeterministic {
    World a, b;
    a.set_seed(12345); b.set_seed(12345);
    bool sawWindow = false, sawHurt = false;
    for (int i = 0; i < 1800; ++i) {
        // Include landed hits and grace-period attempts for both slots.
        if (i % 80 == 0 || i % 80 == 1) {
            a.damage_player((i / 80) % 2, 1);
            b.damage_player((i / 80) % 2, 1);
        }
        tick(a, 1); tick(b, 1);
        for (EntityID id = 0; id < a.entity_count(); ++id) {
            if (!a.has_component<DinoBehaviorComponent>(id)) continue;
            bool open = a.get_component<DinoBehaviorComponent>(id).interruptWindowOpen;
            XCTAssertEqual(open, b.get_component<DinoBehaviorComponent>(id).interruptWindowOpen);
            sawWindow |= open;
        }
        int hurts = a.consume_audio_cues().playerHurts;
        XCTAssertEqual(hurts, b.consume_audio_cues().playerHurts);
        sawHurt |= hurts > 0;
        for (int p = 0; p < kRexMaxPlayers; ++p) {
            XCTAssertEqual(a.player_health(p).hitCount, b.player_health(p).hitCount);
        }
    }
    XCTAssertTrue(sawWindow);
    XCTAssertTrue(sawHurt);
}

@end
