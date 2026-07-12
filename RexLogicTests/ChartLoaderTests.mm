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

    // A species with no loadable character (triceratops asset hasn't landed
    // yet) must fail at parse time, not silently render the wrong boss.
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"metalrex-bad-boss-chart.json"];
    NSString *json = @"{\"rail\":{\"controlPoints\":[[0,0.3,0],[0,0.3,10],[0,0.3,20],[0,0.3,30]]},"
                      @"\"lookAtBeats\":[{\"distance\":0,\"target\":[0,0.3,5]}],"
                      @"\"events\":[],"
                      @"\"boss\":{\"species\":\"triceratops\"}}";
    [json writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];

    bool threw = false;
    try {
        ChartLoader_load_file([path UTF8String]);
    } catch (const std::runtime_error& ex) {
        threw = true;
        XCTAssertTrue(std::string(ex.what()).find("triceratops") != std::string::npos);
    }
    XCTAssertTrue(threw);
}

@end
