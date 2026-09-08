#import <XCTest/XCTest.h>
#include "Simulation/ChartLoader.h"
#include <string>

@interface ChartLoaderTests : XCTestCase
@end

@implementation ChartLoaderTests

- (NSString *)fixturePath {
    NSString *path = [[NSBundle bundleForClass:[self class]] pathForResource:@"m2-test"
                                                                      ofType:@"json"
                                                                 inDirectory:@"assets/charts"];
    XCTAssertNotNil(path);
    return path;
}

- (void)test_validChartParsesRailLookAtBeatsAndEvents {
    LevelChart chart = ChartLoader_load_file([[self fixturePath] UTF8String]);

    XCTAssertTrue(chart.rail.valid());
    XCTAssertEqual(chart.rail.control_points().size(), 7ul);
    XCTAssertGreaterThan(chart.rail.total_length(), 30.f);

    XCTAssertEqual(chart.lookAtBeats.size(), 5ul);
    XCTAssertEqualWithAccuracy(chart.lookAtBeats[1].distance, 5.5f, 0.001f);
    XCTAssertEqualWithAccuracy(chart.lookAtBeats[1].target.x, 2.0f, 0.001f);

    // 9 wave/target/camera beats + 3 scripted boss major_attack QTEs.
    XCTAssertEqual(chart.events.size(), 12ul);
    XCTAssertEqualWithAccuracy(chart.events[1].distance, 8.5f, 0.001f);
    XCTAssertEqual(std::string("moving_target"), chart.events[1].type);
    XCTAssertTrue(chart.events[1].payloadJSON.find("\"slot\":3") != std::string::npos);

    XCTAssertEqual(std::string("raptor_wave"), chart.events[2].type);
    XCTAssertTrue(chart.events[2].raptorWave.valid);
    XCTAssertEqual(chart.events[2].raptorWave.groupSize, 1);
    XCTAssertEqualWithAccuracy(chart.events[2].raptorWave.lanes[0], 0.f, 0.001f);
    XCTAssertEqualWithAccuracy(chart.events[2].raptorWave.spawnGap, 8.f, 0.001f);
    XCTAssertFalse(chart.events[2].raptorWave.usesEntries);
    XCTAssertEqual(chart.events[2].raptorWave.entries[0].archetype, RaptorArchetype::Chase);

    // Events are distance-sorted, so the final-pack raptor wave now sits at
    // index 10 (two major_attack QTEs at 27.5 and 29.5 precede it).
    XCTAssertEqual(std::string("raptor_wave"), chart.events[10].type);
    XCTAssertTrue(chart.events[10].raptorWave.valid);
    XCTAssertEqual(chart.events[10].raptorWave.groupSize, 3);
    XCTAssertEqualWithAccuracy(chart.events[10].distance, 31.0f, 0.001f);

    // Boss major-attack QTEs parse as plain typed events (no special payload),
    // scripted at 27.5 / 29.5 / 31.5.
    XCTAssertEqual(std::string("major_attack"), chart.events[7].type);
    XCTAssertEqualWithAccuracy(chart.events[7].distance, 27.5f, 0.001f);
    XCTAssertEqual(std::string("major_attack"), chart.events[11].type);
    XCTAssertEqualWithAccuracy(chart.events[11].distance, 31.5f, 0.001f);
}

- (void)test_unknownRaptorArchetypeFailsLoudly {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"metalrex-bad-archetype-chart.json"];
    NSString *json =
        @"{"
         "\"rail\":{\"controlPoints\":[[0,0,0],[0,0,4],[0,0,8],[0,0,12]]},"
         "\"lookAtBeats\":[{\"distance\":0,\"target\":[0,0,4]}],"
         "\"events\":[{\"distance\":1,\"type\":\"raptor_wave\","
         "\"payload\":{\"groupSize\":1,"
         "\"entries\":[{\"archetype\":\"teleporter\",\"lane\":0}],"
         "\"holdSeconds\":2,\"attackStaggerSeconds\":0}}]"
         "}";
    [json writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];

    bool threw = false;
    try {
        ChartLoader_load_file([path UTF8String]);
    } catch (const std::runtime_error& ex) {
        threw = true;
        XCTAssertTrue(std::string(ex.what()).find("teleporter") != std::string::npos);
    }
    XCTAssertTrue(threw);
}

- (void)test_missingChartThrowsInsteadOfReturningEmptyLevel {
    XCTAssertThrows(ChartLoader_load_file("/tmp/metalrex-definitely-missing-chart.json"));
}

- (void)test_malformedChartThrowsInsteadOfReturningEmptyLevel {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"metalrex-malformed-chart.json"];
    [@"{\"rail\":{\"controlPoints\":[[0,0,0]]},\"lookAtBeats\":[],\"events\":[]}"
        writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];

    XCTAssertThrows(ChartLoader_load_file([path UTF8String]));
}

- (void)test_malformedRaptorWaveThrowsInsteadOfSilentlySkipping {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"metalrex-bad-raptor-wave-chart.json"];
    NSString *json =
        @"{"
         "\"rail\":{\"controlPoints\":[[0,0,0],[0,0,4],[0,0,8],[0,0,12]]},"
         "\"lookAtBeats\":[{\"distance\":0,\"target\":[0,0,4]}],"
         "\"events\":[{\"distance\":1,\"type\":\"raptor_wave\","
         "\"payload\":{\"groupSize\":3,\"lanes\":[-1,1],\"spawnGap\":8,"
         "\"holdSeconds\":2,\"attackStaggerSeconds\":0.5}}]"
         "}";
    [json writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];

    XCTAssertThrows(ChartLoader_load_file([path UTF8String]));
}


- (void)test_bossBlockParsesAndUnknownSpeciesFailsLoudly {
    LevelChart chart = ChartLoader_load_file([[self fixturePath] UTF8String]);
    XCTAssertTrue(chart.boss.valid);
    XCTAssertEqual(chart.boss.species, std::string("trex"));
    XCTAssertEqual(chart.boss.maxHealth, 40);
    XCTAssertEqual(chart.boss.attackDamage, 30);

    // A misspelled species must fail at parse time, not silently render
    // the wrong boss. All names in the shared mapping are loadable.
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"metalrex-bad-boss-chart.json"];
    NSString *json = @"{\"rail\":{\"controlPoints\":[[0,0.3,0],[0,0.3,10],[0,0.3,20],[0,0.3,30]]},"
                      @"\"lookAtBeats\":[{\"distance\":0,\"target\":[0,0.3,5]}],"
                      @"\"events\":[],"
                      @"\"boss\":{\"species\":\"triceratop\"}}";
    [json writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];

    bool threw = false;
    try {
        ChartLoader_load_file([path UTF8String]);
    } catch (const std::runtime_error& ex) {
        threw = true;
        XCTAssertTrue(std::string(ex.what()).find("triceratop") != std::string::npos);
    }
    XCTAssertTrue(threw);

    // Concrete expectations, NOT derived from DinoSpecies_is_boss_capable:
    // an earlier version of this test asked that predicate what to expect and
    // so passed happily when the predicate was mutated to accept everything.
    // A test that consults the implementation for its oracle proves nothing.
    //
    // trex and velociraptor have authored boss proportions (World's
    // reset_m1_scene) and a major-attack point table. The herbivores render
    // fine as characters but have neither, so accepting one would stage a
    // raptor-sized "boss" running the T-Rex's QTE points — the silent
    // wrong-boss this validation exists to stop. Flip one of these to the
    // load branch when TODOS item 12 gives Triceratops its boss data.
    auto loadWithBoss = [&](NSString *speciesName) {
        NSString *speciesJSON = [json stringByReplacingOccurrencesOfString:@"triceratop"
                                                                withString:speciesName];
        [speciesJSON writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return ChartLoader_load_file(path.UTF8String);
    };

    for (NSString *accepted in @[@"trex", @"velociraptor"]) {
        LevelChart loaded = loadWithBoss(accepted);
        XCTAssertTrue(loaded.boss.valid);
        XCTAssertEqual(loaded.boss.species, std::string(accepted.UTF8String));
    }

    for (NSString *refusedName in @[@"triceratops", @"stegosaurus",
                                    @"parasaurolophus", @"apatosaurus"]) {
        bool refused = false;
        try {
            loadWithBoss(refusedName);
        } catch (const std::runtime_error& ex) {
            refused = true;
            // The error names the offender and lists the real options.
            XCTAssertTrue(std::string(ex.what()).find(refusedName.UTF8String) != std::string::npos);
            XCTAssertTrue(std::string(ex.what()).find("trex") != std::string::npos);
        }
        XCTAssertTrue(refused, @"%@ has no boss data but the chart accepted it as a boss", refusedName);
    }
}

@end
