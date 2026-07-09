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

    XCTAssertEqual(chart.events.size(), 3ul);
    XCTAssertEqualWithAccuracy(chart.events[1].distance, 8.5f, 0.001f);
    XCTAssertEqual(std::string("moving_target"), chart.events[1].type);
    XCTAssertTrue(chart.events[1].payloadJSON.find("\"slot\":3") != std::string::npos);
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

@end
