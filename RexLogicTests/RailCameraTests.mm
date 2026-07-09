#import <XCTest/XCTest.h>
#include "Simulation/ChartLoader.h"
#include "Simulation/World.h"
#include <algorithm>
#include <cmath>
#include <vector>

@interface RailCameraTests : XCTestCase
@end

@implementation RailCameraTests

static LevelChart curvedTestChart(void) {
    LevelChart chart;
    std::vector<RexVec3> points = {
        {0.f, 0.25f, 0.f},
        {0.f, 0.25f, 4.f},
        {3.f, 0.25f, 8.f},
        {-2.f, 0.25f, 12.f},
        {0.f, 0.25f, 18.f},
    };
    chart.rail.build(points, 128);
    chart.lookAtBeats.push_back({0.f, {0.f, 0.5f, 4.f}});
    chart.lookAtBeats.push_back({chart.rail.total_length() * 0.5f, {3.f, 1.f, 9.f}});
    chart.lookAtBeats.push_back({chart.rail.total_length(), {0.f, 0.5f, 18.f}});
    chart.events.push_back({2.f, "test_event", "{}"});
    return chart;
}

- (void)test_arcLengthLookupGivesEqualDistanceButNotEqualRawTStepsThroughCurve {
    LevelChart chart = curvedTestChart();
    float d0 = 2.0f;
    float d1 = 3.5f;
    float d2 = 5.0f;
    float d3 = 6.5f;

    float raw0 = chart.rail.raw_t_at_distance(d0);
    float raw1 = chart.rail.raw_t_at_distance(d1);
    float raw2 = chart.rail.raw_t_at_distance(d2);
    float raw3 = chart.rail.raw_t_at_distance(d3);

    XCTAssertEqualWithAccuracy(d1 - d0, d2 - d1, 0.0001f);
    XCTAssertEqualWithAccuracy(d2 - d1, d3 - d2, 0.0001f);

    float rawStepA = raw1 - raw0;
    float rawStepB = raw2 - raw1;
    float rawStepC = raw3 - raw2;
    XCTAssertGreaterThan(fabsf(rawStepA - rawStepB) + fabsf(rawStepB - rawStepC), 0.02f);

    RexVec3 p0 = chart.rail.position_at_distance(d0);
    RexVec3 p1 = chart.rail.position_at_distance(d1);
    RexVec3 p2 = chart.rail.position_at_distance(d2);
    RexVec3 p3 = chart.rail.position_at_distance(d3);
    XCTAssertEqualWithAccuracy(RexVec3_length(RexVec3_sub(p1, p0)), 1.5f, 0.04f);
    XCTAssertEqualWithAccuracy(RexVec3_length(RexVec3_sub(p2, p1)), 1.5f, 0.04f);
    XCTAssertEqualWithAccuracy(RexVec3_length(RexVec3_sub(p3, p2)), 1.5f, 0.04f);
}

- (void)test_worldCameraAdvancesDistanceLinearlyAndRawTNonlinearly {
    World world;
    world.replace_chart_for_tests(curvedTestChart());
    world.rail_camera().speed = 1.5f;

    world.update(1.f, 1.f);
    float d1 = world.rail_camera().distance;
    float raw1 = world.rail_camera().rawT;
    world.update(1.f, 1.f);
    float d2 = world.rail_camera().distance;
    float raw2 = world.rail_camera().rawT;
    world.update(1.f, 1.f);
    float d3 = world.rail_camera().distance;
    float raw3 = world.rail_camera().rawT;

    XCTAssertEqualWithAccuracy(d2 - d1, 1.5f, 0.001f);
    XCTAssertEqualWithAccuracy(d3 - d2, 1.5f, 0.001f);
    XCTAssertGreaterThan(fabsf((raw2 - raw1) - (raw3 - raw2)), 0.005f);
}

- (void)test_cameraFacesBackwardAlongRail {
    // Jeep scenario: the camera advances along the rail but aims at a rail
    // point BEHIND it — the player shoots at pursuers from the back of the
    // jeep. The chart's authored lookAtBeats are intentionally unused here.
    World world;
    LevelChart chart = curvedTestChart();
    world.replace_chart_for_tests(chart);

    world.update(1.f / 120.f, 1.f / 120.f);

    const RailCameraState& camera = world.rail_camera();
    RexVec3 expected = chart.rail.position_at_distance(std::max(0.f, camera.distance - 4.f));
    XCTAssertEqualWithAccuracy(camera.lookAtX, expected.x, 0.01f);
    XCTAssertEqualWithAccuracy(camera.lookAtY, expected.y, 0.01f);
    XCTAssertEqualWithAccuracy(camera.lookAtZ, expected.z, 0.01f);

    // View direction opposes the direction of travel.
    RexVec3 tangent = chart.rail.tangent_at_distance(camera.distance);
    float forwardDotTravel = (camera.lookAtX - camera.positionX) * tangent.x
                           + (camera.lookAtY - camera.positionY) * tangent.y
                           + (camera.lookAtZ - camera.positionZ) * tangent.z;
    XCTAssertLessThan(forwardDotTravel, 0.f);
}

- (void)test_cameraReachingRailEndLoopsRatherThanHanging {
    // Regresses a real freeze: camera.distance used to clamp at the rail's
    // end and stay there permanently, which made the target-respawn loop in
    // update_targets unable to ever settle (it kept resetting to a small
    // distance that was still behind the stuck camera, re-triggering
    // forever) — an actual hang reported by the builder testing on-device,
    // reproducible at ~20-30s of continuous play. This test runs enough
    // ticks to cross the rail's length several times over; if either the
    // camera-loop fix or the while-loop's iteration cap regressed, this
    // test itself would hang (and time out the build) rather than fail
    // cleanly, which is still a meaningful signal.
    World world;
    LevelChart chart = curvedTestChart();
    world.replace_chart_for_tests(chart);
    world.rail_camera().speed = chart.rail.total_length() * 4.f; // cross the whole rail every tick

    for (int i = 0; i < 500; ++i) {
        world.update(1.f / 120.f, 1.f / 120.f);
    }

    float distance = world.rail_camera().distance;
    XCTAssertGreaterThanOrEqual(distance, 0.f);
    XCTAssertLessThanOrEqual(distance, chart.rail.total_length());
    XCTAssertTrue(std::isfinite(world.target(3).worldY));
    XCTAssertTrue(std::isfinite(world.target(3).railDistance));
}

- (void)test_degenerateSplineThrowsRatherThanProducingNaNTable {
    std::vector<RexVec3> points = {
        {1.f, 1.f, 1.f},
        {1.f, 1.f, 1.f},
        {1.f, 1.f, 1.f},
    };
    RailSpline spline;
    XCTAssertThrows(spline.build(points, 16));
}

@end
