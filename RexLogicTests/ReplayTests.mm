#import <XCTest/XCTest.h>
#include "Simulation/World.h"
#include "Simulation/Systems/ScreenShakeSystem.h"
#import "RexGameHost.h"
#include <bit>
#include <limits>
#include <sstream>
#include <fstream>

@interface ReplayTests : XCTestCase
@end
@implementation ReplayTests
- (void)setUp { ReticleSystem_set_tuning({}); }
- (void)tearDown { ReticleSystem_set_tuning({}); }

- (NSString*)temporaryPath {
    NSString* dir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [self addTeardownBlock:^{ [[NSFileManager defaultManager] removeItemAtPath:dir error:nil]; }];
    return [dir stringByAppendingPathComponent:@"replay.txt"];
}

- (LevelChart)waveChart {
    NSBundle* bundle = [NSBundle bundleForClass:self.class];
    NSString* path = [bundle pathForResource:@"m2-test" ofType:@"json" inDirectory:@"assets/charts"];
    NSMutableDictionary* json = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path]
        options:NSJSONReadingMutableContainers error:nil];
    NSMutableDictionary* pack = nil;
    for (NSMutableDictionary* event in json[@"events"]) {
        if ([event[@"type"] isEqual:@"raptor_wave"] && [event[@"payload"][@"label"] isEqual:@"pack-test"])
            pack = event;
    }
    XCTAssertNotNil(pack);
    pack[@"distance"] = @0;
    json[@"events"] = @[pack];
    json[@"boss"][@"arrivalDistance"] = @1000;
    // Keep source identity tied to actual bytes, including this authored fixture.
    NSData* data = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingSortedKeys error:nil];
    NSString* fixture = [[self temporaryPath] stringByAppendingString:@".json"];
    XCTAssertTrue([data writeToFile:fixture atomically:YES]);
    return ChartLoader_load_file(fixture.UTF8String);
}

static void configure(World& world, const LevelChart& chart) {
    world.replace_chart_for_tests(chart);
    world.set_seed(0xC0FFEEu);
}
static void tick(World& world) { world.update(1.f/120.f, 1.f/120.f); }
static void raggedReplay(World& world) {
    int frame = 0;
    while (!world.replay_finished() && frame < 10000) {
        float dt = frame == 7 ? 0.37f : (frame % 2 ? 1.f/144.f : 1.f/60.f);
        world.update(dt, dt);
        ++frame;
    }
}
- (void)assertSame:(const World&)a other:(const World&)b {
    std::string diff = ScoreTimeline_first_difference(a.score_timeline(), b.score_timeline());
    XCTAssertTrue(diff.empty(), @"%s", diff.c_str());
    XCTAssertEqual(a.tick_count(), b.tick_count());
    for (int p = 0; p < kRexMaxPlayers; ++p) {
        XCTAssertEqual(a.score(p).score, b.score(p).score);
        XCTAssertEqual(a.score(p).currentStreak, b.score(p).currentStreak);
        XCTAssertEqual(a.score(p).bestStreak, b.score(p).bestStreak);
        XCTAssertEqual(a.score(p).shotsFired, b.score(p).shotsFired);
        XCTAssertEqual(a.score(p).shotsHit, b.score(p).shotsHit);
        XCTAssertEqual(a.score(p).interruptSuccesses, b.score(p).interruptSuccesses);
        XCTAssertEqual(a.player_health(p).health, b.player_health(p).health);
        XCTAssertEqual(a.player_health(p).hitCount, b.player_health(p).hitCount);
        XCTAssertEqual(a.player_health(p).sittingOut, b.player_health(p).sittingOut);
        XCTAssertEqual(a.reticle(p).x, b.reticle(p).x);
        XCTAssertEqual(a.reticle(p).y, b.reticle(p).y);
    }
}
- (void)test_roundTripEveryInputBitForEveryPlayer {
    InputRecording log(4);
    // Exercise nine-digit values, signed zero, and exponent notation; no struct
    // memcmp, because padding bytes are not part of the input contract.
    const float values[] = {0.f, -0.f, 0.123456791f, -0.987654328f,
        std::numeric_limits<float>::min(), std::numeric_limits<float>::max(), 1.00000012f};
    for (int t = 0; t < 37; ++t) {
        InputState row[4]{};
        for (int p = 0; p < 4; ++p) row[p] = {values[(t+p)%7], values[(t+p+1)%7],
            values[(t+p+2)%7], values[(t+p+3)%7], bool(t&1), bool(t&2), bool(t&4)};
        log.appendTick(row, 4);
    }
    NSString* path = [self temporaryPath];
    std::string error;
    XCTAssertTrue(log.saveToFile(path.UTF8String, &error), @"%s", error.c_str());
    InputRecording loaded;
    XCTAssertTrue(loaded.loadFromFile(path.UTF8String, &error), @"%s", error.c_str());
    XCTAssertEqual(loaded.tickCount(), log.tickCount());
    XCTAssertEqual(loaded.playerCount(), log.playerCount());
    for (size_t t = 0; t < log.tickCount(); ++t) for (int p = 0; p < 4; ++p) {
        const auto& a = log.inputAt(t, p); const auto& b = loaded.inputAt(t, p);
        XCTAssertEqual(std::bit_cast<uint32_t>(a.stickX), std::bit_cast<uint32_t>(b.stickX));
        XCTAssertEqual(std::bit_cast<uint32_t>(a.stickY), std::bit_cast<uint32_t>(b.stickY));
        XCTAssertEqual(std::bit_cast<uint32_t>(a.gyroDeltaX), std::bit_cast<uint32_t>(b.gyroDeltaX));
        XCTAssertEqual(std::bit_cast<uint32_t>(a.gyroDeltaY), std::bit_cast<uint32_t>(b.gyroDeltaY));
        XCTAssertEqual(a.recenter, b.recenter); XCTAssertEqual(a.fire, b.fire); XCTAssertEqual(a.pause, b.pause);
    }
}
- (void)test_fullWaveDiskReplayTimelineAndRaggedFramesIgnoreLiveInput {
    LevelChart chart = [self waveChart];
    World record; configure(record, chart);
    record.begin_recording(4);
    bool sawRaptor = false;
    for (int t = 0; t < 1800; ++t) {
        InputState input{};
        input.fire = (t % 90) < 50;
        input.gyroDeltaX = (t % 40 < 20 ? 0.0003f : -0.0003f);
        input.recenter = t % 300 == 0;
        record.set_input(input, 0);
        tick(record);
        for (EntityID id = 0; id < record.entity_count(); ++id)
            if (record.has_component<DinoBehaviorComponent>(id)) {
                const auto& d = record.get_component<DinoBehaviorComponent>(id);
                sawRaptor |= !d.isBoss && d.activeInEncounter;
            }
    }
    XCTAssertTrue(sawRaptor);
    for (EntityID id = 0; id < record.entity_count(); ++id)
        if (record.has_component<DinoBehaviorComponent>(id)) {
            const auto& d = record.get_component<DinoBehaviorComponent>(id);
            if (!d.isBoss) XCTAssertFalse(d.activeInEncounter, @"full wave must finish");
        }
    XCTAssertFalse(record.score_timeline().empty());
    XCTAssertGreaterThan(record.score(0).score, 0);
    XCTAssertEqual(record.recording()->tickCount(), record.tick_count());
    NSString* path = [self temporaryPath]; std::string error;
    XCTAssertTrue(record.recording()->saveToFile(path.UTF8String, &error));
    InputRecording log;
    XCTAssertTrue(log.loadFromFile(path.UTF8String, &error), @"%s", error.c_str());
    XCTAssertTrue(log.header.matches(record.recording()->header, &error));
    World uniform, injected, ragged;
    configure(uniform, chart); configure(injected, chart); configure(ragged, chart);
    uniform.begin_replay(log); injected.begin_replay(log); ragged.begin_replay(log);
    // Two replay worlds interleaved in the same process, one with live controller noise.
    for (size_t t = 0; t < log.tickCount(); ++t) {
        tick(uniform);
        InputState noise{1.f, -1.f, 0.9f, -0.9f, true, true, true};
        for (int p = 0; p < 4; ++p) injected.set_input(noise, p);
        tick(injected);
    }
    raggedReplay(ragged);
    XCTAssertTrue(uniform.replay_finished()); XCTAssertTrue(ragged.replay_finished());
    [self assertSame:record other:uniform]; [self assertSame:record other:injected]; [self assertSame:record other:ragged];
    uint64_t ended = ragged.tick_count(); ragged.update(1.f, 1.f);
    XCTAssertEqual(ragged.tick_count(), ended);
    // A stable artifact for the before/after comments-only verification.
    std::string timeline;
    for (const auto& e : record.score_timeline()) timeline += std::to_string(e.tickIndex) + ":"
        + std::to_string(e.player) + ":" + std::to_string((int)e.event) + ":" + std::to_string((int)e.species) + ";";
    NSLog(@"ReplayTimeline: %s", timeline.c_str());
    // Optional cross-build proof: preserve the original input bytes and compare
    // the replay's serialized timeline, never regenerate the expectation.
    if (const char* dir = getenv("REX_TIMELINE_PROOF_DIR")) {
        std::string root(dir), recordingPath = root + "/wave.replay";
        std::string expectedPath = root + "/before.timeline";
        if (getenv("REX_TIMELINE_PROOF_RECORD")) {
            XCTAssertTrue(record.recording()->saveToFile(recordingPath.c_str(), &error));
            std::ofstream out(expectedPath, std::ios::binary);
            out << timeline;
            XCTAssertTrue(out.good());
        } else {
            InputRecording before;
            XCTAssertTrue(before.loadFromFile(recordingPath.c_str(), &error), @"%s", error.c_str());
            World across; configure(across, chart); across.begin_replay(before);
            raggedReplay(across);
            std::string actual;
            for (const auto& e : across.score_timeline()) actual += std::to_string(e.tickIndex) + ":"
                + std::to_string(e.player) + ":" + std::to_string((int)e.event) + ":" + std::to_string((int)e.species) + ";";
            std::ifstream in(expectedPath, std::ios::binary);
            XCTAssertTrue(in.good());
            std::string expected((std::istreambuf_iterator<char>(in)), {});
            XCTAssertFalse(expected.empty());
            XCTAssertEqual(actual, expected, @"Cross-build score timeline must be byte-identical");
            std::ofstream out(root + "/after.timeline", std::ios::binary); out << actual;
        }
    }
}
- (void)test_eachHeaderMismatchNamesItsFieldBeforeAnyTick {
    World original; original.begin_recording(4); tick(original);
    const auto base = *original.recording();
    for (const auto& [field, value] : base.header.fields) {
        auto changed = base;
        changed.header.fields[field] = value + "_changed";
        NSString* path = [self temporaryPath];
        XCTAssertTrue(changed.saveToFile(path.UTF8String));
        InputRecording loaded;
        XCTAssertTrue(loaded.loadFromFile(path.UTF8String));
        World replay;
        bool rejected = false;
        try { replay.begin_replay(loaded); }
        catch (const std::exception& e) {
            rejected = true;
            XCTAssertTrue(std::string(e.what()).find(field) != std::string::npos, @"%s", e.what());
        }
        XCTAssertTrue(rejected, @"%s", field.c_str());
        try { tick(replay); XCTFail(@"rejected replay must not run"); }
        catch (const std::exception&) {}
        XCTAssertEqual(replay.tick_count(), 0ull);
    }
    for (const char* field : {"seed", "chart.hash", "ReticleTuning.gyroSensitivityH"}) {
        auto missing = base; missing.header.fields.erase(field);
        World replay; bool rejected = false;
        try { replay.begin_replay(missing); }
        catch (const std::exception& e) { rejected = true; XCTAssertTrue(std::string(e.what()).find(field) != std::string::npos); }
        XCTAssertTrue(rejected);
    }
}
- (void)test_actualChartByteEditIsRejected {
    World original;
    NSBundle* bundle = [NSBundle bundleForClass:self.class];
    NSString* source = [bundle pathForResource:@"m2-test" ofType:@"json" inDirectory:@"assets/charts"];
    NSString* changedPath = [[[self temporaryPath] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"m2-test.json"];
    NSMutableData* bytes = [[NSData dataWithContentsOfFile:source] mutableCopy];
    [bytes appendBytes:"\n" length:1];
    XCTAssertTrue([bytes writeToFile:changedPath atomically:YES]);
    World changed; changed.replace_chart_for_tests(ChartLoader_load_file(changedPath.UTF8String));
    XCTAssertEqual(original.chart().sourceName, changed.chart().sourceName);
    XCTAssertNotEqual(original.chart().sourceHash, changed.chart().sourceHash);
    original.begin_recording(4);
    bool rejected = false;
    try { changed.begin_replay(*original.recording()); }
    catch (const std::exception& e) { rejected = true; XCTAssertTrue(std::string(e.what()).find("chart.hash") != std::string::npos); }
    XCTAssertTrue(rejected); XCTAssertEqual(changed.tick_count(), 0ull);
}
- (void)test_tuningIsFrozenPerRecordingAndReplay {
    World original; original.begin_recording(4);
    InputState input{}; input.gyroDeltaX = 0.001f;
    original.set_input(input);
    ReticleTuning changed; changed.gyroSensitivityH = 1.f;
    ReticleSystem_set_tuning(changed);
    tick(original);
    ReticleSystem_set_tuning({});
    World replay; replay.begin_replay(*original.recording());
    ReticleSystem_set_tuning(changed);
    tick(replay);
    [self assertSame:original other:replay];
}
- (void)test_shakeIsIsolatedAndStillDrawsOnceWhenIdle {
    World a, b;
    a.set_seed(7); b.set_seed(7);
    ScreenShakeSystem_trigger(a, 0.5f);
    ScreenShakeSystem_update(a, 1.f/120.f);
    ScreenShakeSystem_update(b, 1.f/120.f);
    XCTAssertGreaterThan(simd_length(ScreenShakeSystem_offset(a)), 0.f);
    XCTAssertEqual(simd_length(ScreenShakeSystem_offset(b)), 0.f);
    XCTAssertEqual(a.rand_u32(), b.rand_u32());
    auto offset = ScreenShakeSystem_offset(a);
    { World other; ScreenShakeSystem_trigger(other, 2.f); ScreenShakeSystem_update(other, 1.f/120.f); }
    XCTAssertEqual(ScreenShakeSystem_offset(a).x, offset.x);
    XCTAssertEqual(ScreenShakeSystem_offset(a).y, offset.y);
}
- (void)test_gyroAggregateOneSecondUniformAndRaggedUnchanged {
    World uniform, ragged;
    InputState input{}; input.gyroDeltaX = 0.3f / 120.f; input.gyroDeltaY = -0.24f / 120.f;
    uniform.set_input(input); ragged.set_input(input);
    for (int i = 0; i < 120; ++i) tick(uniform);
    int frame = 0;
    while (ragged.tick_count() < 100) {
        float dt = frame == 4 ? 0.2f : frame % 2 ? 1.f/144.f : 1.f/60.f;
        ragged.update(dt, dt);
        ++frame;
    }
    // Consume the remaining ticks of one simulation second, leaving any
    // fractional accumulator remainder untouched.
    float remaining = (120 - ragged.tick_count()) * (1.f/120.f);
    ragged.update(remaining, remaining);
    XCTAssertEqual(ragged.tick_count(), 120ull);
    XCTAssertEqual(uniform.reticle(0).x, ragged.reticle(0).x);
    XCTAssertEqual(uniform.reticle(0).y, ragged.reticle(0).y);
    XCTAssertEqualWithAccuracy(uniform.reticle(0).x - 0.5f, 0.3f * 0.34f, 0.00001f);
    XCTAssertEqualWithAccuracy(uniform.reticle(0).y - 0.5f, -0.24f * 0.28f, 0.00001f);
}
- (void)test_firstDifferenceNamesEarliestTickIncludingMissingEvents {
    ScoreTimeline a{{4, 0, DinoScoreEvent::Hit, DinoSpecies::Velociraptor},
                    {19, 1, DinoScoreEvent::InterruptFail, DinoSpecies::Velociraptor}};
    auto b = a; b[1].tickIndex = 20;
    XCTAssertTrue(ScoreTimeline_first_difference(a,b).find("tickIndex 19") != std::string::npos);
    b.pop_back();
    XCTAssertTrue(ScoreTimeline_first_difference(a,b).find("tickIndex 19") != std::string::npos);
    b = a; b[0].player = 1;
    XCTAssertTrue(ScoreTimeline_first_difference(a,b).find("tickIndex 4") != std::string::npos);
}
- (void)test_titleAndFrozenTicksAreCapturedAndEmptyReplayStops {
    World record; record.enter_title(); record.begin_recording(4);
    tick(record);
    InputState fire{}; fire.fire = true; record.set_input(fire); tick(record);
    XCTAssertEqual(record.phase(), GamePhase::Playing);
    XCTAssertEqual(record.recording()->tickCount(), 2ul);
    World replay; replay.enter_title(); replay.begin_replay(*record.recording());
    raggedReplay(replay); [self assertSame:record other:replay];
    World frozen; frozen.complete_level(); frozen.begin_recording(4);
    tick(frozen); XCTAssertEqual(frozen.recording()->tickCount(), 1ul);
    World empty; World source; source.begin_recording(4);
    empty.begin_replay(*source.recording()); XCTAssertTrue(empty.replay_finished());
    tick(empty); XCTAssertEqual(empty.tick_count(), 0ull);
}

- (void)test_tickSeamCapturesHeldInputsAtRaggedFrameBoundaries {
    World record; record.begin_recording(4);
    for (int frame = 0; frame < 80; ++frame) {
        InputState input{frame % 2 ? 0.03f : -0.03f, 0.f, frame * 0.000001f, 0.f, false, bool(frame%3), false};
        record.set_input(input);
        size_t before = record.tick_count();
        float dt = frame == 7 ? 0.31f : frame % 2 ? 1.f/144.f : 1.f/60.f;
        record.update(dt, dt);
        XCTAssertEqual(record.recording()->tickCount(), record.tick_count());
        for (size_t t = before; t < record.tick_count(); ++t) {
            XCTAssertEqual(record.recording()->inputAt(t, 0).stickX, input.stickX);
            XCTAssertEqual(record.recording()->inputAt(t, 0).gyroDeltaX, input.gyroDeltaX);
            XCTAssertEqual(record.recording()->inputAt(t, 0).fire, input.fire);
        }
    }
    World replay; replay.begin_replay(*record.recording());
    while (!replay.replay_finished()) tick(replay);
    [self assertSame:record other:replay];
}

// Restore process environment even when a test throws.
struct ReplayEnvironment {
    std::optional<std::string> record, replay;
    ReplayEnvironment() {
        if (const char* p = getenv("REX_RECORD")) record = p;
        if (const char* p = getenv("REX_REPLAY")) replay = p;
        unsetenv("REX_RECORD"); unsetenv("REX_REPLAY");
    }
    ~ReplayEnvironment() {
        if (record) setenv("REX_RECORD", record->c_str(), 1); else unsetenv("REX_RECORD");
        if (replay) setenv("REX_REPLAY", replay->c_str(), 1); else unsetenv("REX_REPLAY");
    }
};
- (void)test_hostRecordAndReplayHooksRoundTripAndFlush {
    ReplayEnvironment environment;
    NSString* path = [self temporaryPath];
    setenv("REX_RECORD", path.UTF8String, 1);
    RexGameHost* record = [[RexGameHost alloc] initHeadless];
    record.rngSeedOverride = 1234;
    InputState fire{}; fire.fire = true;
    [record setInputState:fire];
    for (int i = 0; i < 137; ++i) [record advanceFrame:1.f/120.f];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"NSApplicationWillTerminateNotification" object:nil];
    InputRecording log; std::string error;
    XCTAssertTrue(log.loadFromFile(path.UTF8String, &error), @"%s", error.c_str());
    XCTAssertEqual(log.tickCount(), 137ul);
    XCTAssertEqual(log.header.fields.at("seed"), std::string("1234"));
    unsetenv("REX_RECORD"); setenv("REX_REPLAY", path.UTF8String, 1);
    RexGameHost* replay = [[RexGameHost alloc] initHeadless];
    for (int i = 0; i < 200; ++i) {
        InputState noise{1, 1, 1, 1, true, false, false};
        [replay setInputState:noise];
        [replay advanceFrame:1.f/60.f];
    }
    XCTAssertEqual([record shotCountForPlayer:0], [replay shotCountForPlayer:0]);
    XCTAssertGreaterThan([replay shotCountForPlayer:0], 0u);
    RexGameHost* mismatch = [[RexGameHost alloc] initHeadless];
    mismatch.rngSeedOverride = 456;
    @try { [mismatch advanceFrame:1.f/120.f]; XCTFail(@"seed mismatch must throw"); }
    @catch (NSException* e) { XCTAssertTrue([e.reason containsString:@"seed"]); }
    XCTAssertThrowsSpecificNamed([mismatch advanceFrame:1.f/120.f], NSException, @"RexReplayError");
    XCTAssertEqual([mismatch shotCountForPlayer:0], 0u);
}
- (void)test_hostReconstructsTitleReplayBeforeConsumingInput {
    ReplayEnvironment environment;
    World record; record.enter_title(); record.begin_recording(4);
    tick(record);
    InputState fire{}; fire.fire = true; record.set_input(fire);
    for (int i = 0; i < 120; ++i) tick(record);
    NSString* path = [self temporaryPath];
    XCTAssertTrue(record.recording()->saveToFile(path.UTF8String));
    setenv("REX_REPLAY", path.UTF8String, 1);
    RexGameHost* replay = [[RexGameHost alloc] initHeadless];
    for (int i = 0; i < 121; ++i) [replay advanceFrame:1.f/120.f];
    XCTAssertEqual([replay shotCountForPlayer:0], record.reticle(0).shotCount);
}
- (void)test_corruptFilesFailWithoutReplacingLoadedRecording {
    NSString* path = [self temporaryPath];
    InputRecording log(1); InputState input{}; input.fire = true; log.appendTick(&input, 1);
    XCTAssertTrue(log.saveToFile(path.UTF8String));
    InputRecording loaded; XCTAssertTrue(loaded.loadFromFile(path.UTF8String));
    NSArray<NSString*>* bad = @[
        @"metalrex_replay_v2 1 0\nfields 0\n",
        @"metalrex_replay_v1 5 0\nfields 0\n",
        @"metalrex_replay_v1 1 1\nfields 0\n0 0",
        @"metalrex_replay_v1 1 0\nfields 2\nseed 1\nseed 2\n",
        @"metalrex_replay_v1 1 1\nfields 0\n0 0 0 0 0 2 0\n",
        @"metalrex_replay_v1 1 0\nfields 0\nextra"
    ];
    for (NSString* text in bad) {
        XCTAssertTrue([text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]);
        std::string error;
        XCTAssertFalse(loaded.loadFromFile(path.UTF8String, &error));
        XCTAssertFalse(error.empty());
        XCTAssertEqual(loaded.tickCount(), 1ul);
        XCTAssertTrue(loaded.inputAt(0,0).fire);
    }
}
@end
