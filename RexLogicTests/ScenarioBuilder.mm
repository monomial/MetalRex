#import "ScenarioBuilder.h"
#import <XCTest/XCTest.h>
#include "Simulation/World.h"

// Only exists to give +bundleForClass: something in this target to resolve.
@interface RexScenarioBundleMarker : NSObject @end
@implementation RexScenarioBundleMarker @end

static NSMutableDictionary *loadBaseChartJSON() {
    NSBundle *bundle = [NSBundle bundleForClass:[RexScenarioBundleMarker class]];
    NSString *path = [bundle pathForResource:@"m2-test" ofType:@"json" inDirectory:@"assets/charts"];
    NSCAssert(path != nil, @"Scenario: assets/charts/m2-test.json missing from the test bundle");
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSCAssert(data != nil, @"Scenario: could not read m2-test.json");
    NSMutableDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                               options:NSJSONReadingMutableContainers
                                                                 error:nil];
    NSCAssert(json != nil, @"Scenario: m2-test.json did not parse");
    return json;
}

Scenario::Scenario() : _json(loadBaseChartJSON()), _lastPath(nil), _seed(0xC0FFEEu) {}

Scenario& Scenario::onlyWave(NSString *label) {
    NSMutableDictionary *found = nil;
    for (NSMutableDictionary *event in _json[@"events"]) {
        if ([event[@"type"] isEqual:@"raptor_wave"] && [event[@"payload"][@"label"] isEqual:label]) {
            found = event;
            break;
        }
    }
    NSCAssert(found != nil, @"Scenario: no raptor_wave labelled '%@' in m2-test.json", label);
    found[@"distance"] = @0;
    _json[@"events"] = [@[found] mutableCopy];
    return *this;
}

Scenario& Scenario::noBoss() {
    // Out of reach rather than absent: the chart schema requires a boss block,
    // and an unreachable arrivalDistance is how the existing fixtures do it.
    _json[@"boss"][@"arrivalDistance"] = @1000;
    return *this;
}

Scenario& Scenario::noArena() {
    _json[@"arena"][@"waves"] = @0;
    return *this;
}

Scenario& Scenario::seed(uint32_t s) { _seed = s; return *this; }

LevelChart Scenario::build() {
    NSData *data = [NSJSONSerialization dataWithJSONObject:_json
                                                  options:NSJSONWritingSortedKeys
                                                    error:nil];
    NSCAssert(data != nil, @"Scenario: chart did not serialize");
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    _lastPath = [dir stringByAppendingPathComponent:@"scenario.json"];
    BOOL wrote = [data writeToFile:_lastPath atomically:YES];
    NSCAssert(wrote, @"Scenario: could not write fixture to %@", _lastPath);
    return ChartLoader_load_file(_lastPath.UTF8String);
}

void Scenario::applyTo(World &world) {
    world.replace_chart_for_tests(build());
    world.set_seed(_seed);
}
