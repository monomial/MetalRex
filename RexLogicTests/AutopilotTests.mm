#import <XCTest/XCTest.h>
#include "Simulation/World.h"
#include "Simulation/Systems/AutopilotSystem.h"

// The autopilot's real job is to be watchable (scripts/capture-clip.sh), and
// a clip only proves what a human sees in it. These tests prove the parts a
// clip cannot: that the bot actually plays — joins from the title, lands
// shots, survives the boss, reaches the end — and that a full act runs to
// completion unattended without stalling.
//
// This doubles as the project's soak test. It is the only test that drives
// every system together for a whole act, so a wave that never clears or a
// boss that never resolves fails HERE rather than in front of a person.
@interface AutopilotTests : XCTestCase
@end

@implementation AutopilotTests

static constexpr float kDt = 1.f / 120.f;

// Runs the bot until `done` or the budget runs out. Returns ticks spent.
static int run_bot(World& world, AutopilotState& bot, int maxTicks,
                   bool (^done)(const World&)) {
    int ticks = 0;
    while (ticks < maxTicks && !done(world)) {
        world.set_input(AutopilotSystem_input(world, bot, 0), 0);
        world.update(kDt);
        ++ticks;
    }
    return ticks;
}

- (void)test_botJoinsFromTitleAndStartsSolo {
    World world;
    world.enter_title();
    AutopilotState bot;

    int ticks = run_bot(world, bot, 600, ^(const World& w) {
        return w.phase() == GamePhase::Playing;
    });

    XCTAssertEqual(world.phase(), GamePhase::Playing,
                   @"bot never got past the title in %d ticks", ticks);
    XCTAssertTrue(world.reticle(0).active);
    XCTAssertFalse(world.reticle(1).active, @"solo start must not drag P2 in");
}

- (void)test_botLandsShotsOnTheFirstWave {
    World world;   // constructs Playing, P1+P2 active
    AutopilotState bot;

    // 30 seconds is well past the chart's first several waves.
    run_bot(world, bot, 120 * 30, ^(const World& w) {
        return w.score(0).shotsHit >= 5;
    });

    const PlayerScoreState& score = world.score(0);
    XCTAssertGreaterThanOrEqual(score.shotsHit, 5,
        @"bot hit %d of %d shots — aiming through the stick path is broken",
        score.shotsHit, score.shotsFired);
    XCTAssertGreaterThan(score.score, 0);
}

// The bot leads with the interrupt window, because that is where this
// game's points are: shooting a dino mid-lunge denies the attack, shooting
// it at any other time is chip damage. Driven directly rather than through
// a played act, for a reason worth recording: across a whole act the bot
// sees roughly 0.16 SECONDS of open interrupt window, because an accurate
// player kills every raptor during Approach and it never reaches its lunge.
// That is a real observation about the game (see docs/PLAN-DEMO-CAPTURE.md),
// not something to paper over by making the bot shoot worse.
- (void)test_botPrefersTheDinoWhoseInterruptWindowIsOpen {
    World world;

    // Two live dinos on opposite sides of the reticle. The nearer one (left)
    // is merely approaching; the farther one (right) is mid-lunge.
    EntityID approaching = kInvalidEntity, lunging = kInvalidEntity;
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.has_component<DinoBehaviorComponent>(id)) continue;
        if (world.get_component<DinoBehaviorComponent>(id).species != DinoSpecies::Velociraptor) continue;
        if (approaching == kInvalidEntity) approaching = id;
        else { lunging = id; break; }
    }
    XCTAssertNotEqual(approaching, kInvalidEntity);
    XCTAssertNotEqual(lunging, kInvalidEntity);

    DinoBehaviorComponent& near = world.get_component<DinoBehaviorComponent>(approaching);
    DinoBehaviorComponent& far = world.get_component<DinoBehaviorComponent>(lunging);
    near.active = far.active = true;
    near.activeInEncounter = far.activeInEncounter = true;
    near.state = DinoBehaviorState::Approach;
    near.interruptWindowOpen = false;
    far.state = DinoBehaviorState::Attack;
    far.interruptWindowOpen = true;

    TargetComponent& nearTarget = world.target(near.targetIndex);
    TargetComponent& farTarget = world.target(far.targetIndex);
    nearTarget = TargetComponent{};
    farTarget = TargetComponent{};
    nearTarget.active = farTarget.active = true;
    nearTarget.screenX = 0.35f;  nearTarget.screenY = 0.5f;
    farTarget.screenX  = 0.75f;  farTarget.screenY  = 0.5f;
    // The approaching dino is even front-most, which is the tie-breaker the
    // bot uses when nothing is lunging — so only the window can explain a
    // rightward steer.
    nearTarget.railDistance = 10.f;
    farTarget.railDistance = 2.f;

    world.reticle(0).x = 0.5f;
    world.reticle(0).y = 0.5f;

    AutopilotState bot;
    InputState in = AutopilotSystem_input(world, bot, 0);
    XCTAssertGreaterThan(in.stickX, 0.f,
        @"bot steered away from the open interrupt window toward the closer, "
        @"front-most dino — it is shooting, not playing");
}

// Soak: the whole act, unattended. Catches a wave that never clears, a boss
// QTE that never resolves, and an arena that never completes.
- (void)test_botPlaysTheWholeActToCompletion {
    World world;
    AutopilotState bot;

    // Eight minutes of sim for an act that runs a few. Generous on purpose:
    // this asserts "terminates", not "terminates quickly".
    int ticks = run_bot(world, bot, 120 * 60 * 8, ^(const World& w) {
        return w.level_complete();
    });

    XCTAssertTrue(world.level_complete(),
        @"act never completed in %d ticks (%.0fs): rail at %.1f, arena %s, boss QTEs %d/%d",
        ticks, ticks * kDt, world.rail_camera().distance,
        world.arena_active() ? "active" : "inactive",
        world.scripted_major_attacks_done(), world.scripted_major_attacks_total());

    // A run that "completed" with nothing shot would be a stall the budget
    // happened to outlast, not a played act.
    XCTAssertGreaterThan(world.score(0).shotsHit, 10);
    XCTAssertEqual(world.scripted_major_attacks_done(),
                   world.scripted_major_attacks_total(),
                   @"act ended without resolving every scripted boss QTE");
}

// The grade panel must not be a dead end for an unattended run: the bot
// pulses fire and the next run starts.
- (void)test_botStartsAnotherRunFromTheGradeScreen {
    World world;
    AutopilotState bot;
    run_bot(world, bot, 120 * 60 * 8, ^(const World& w) { return w.level_complete(); });
    XCTAssertTrue(world.level_complete(), @"precondition: act completes");

    run_bot(world, bot, 120 * 20, ^(const World& w) { return !w.level_complete(); });
    XCTAssertFalse(world.level_complete(), @"bot parked on the grade screen");
}

@end
