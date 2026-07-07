#import <XCTest/XCTest.h>
#import "RexGameHost.h"
#include "Simulation/World.h"

// Proves the vendored ECS/tick machinery compiles and runs standalone before
// any MetalRex-specific systems exist. Extend per the design doc's Test Plan
// (ReticleInputTests.mm, RailCameraTests.mm, ChartLoaderTests.mm,
// DinoBehaviorTests.mm, ScoringTests.mm, HealthTests.mm, DeterminismTests.mm)
// as each system lands.

@interface WorldSmokeTests : XCTestCase
@end

@implementation WorldSmokeTests

- (void)test_deferCreate_returnsSequentialIDs {
    World world;
    EntityID a = world.defer_create();
    EntityID b = world.defer_create();
    XCTAssertNotEqual(a, b);
    XCTAssertEqual(b, a + 1);
}

- (void)test_update_doesNotCrash {
    World world;
    XCTAssertNoThrow(world.update(0.0f, 0.0f));
}

- (void)test_fixedTick_120Hz_doesNotCrash {
    World world;
    for (int i = 0; i < 120; ++i) {
        XCTAssertNoThrow(world.update(1.0f / 120.0f, 1.0f / 120.0f));
    }
}

- (void)test_rexGameHost_headlessAdvanceFrame {
    RexGameHost *host = [[RexGameHost alloc] initHeadless];
    host.rngSeedOverride = 1234;
    host.fixedFrameDt = 1.0f / 120.0f;
    InputState input = {0.25f, -0.5f, 0.1f, -0.2f, true, true, false};
    [host setInputState:input forPlayer:0];

    XCTAssertEqual([host currentInputStateForPlayer:0].stickX, 0.25f);
    XCTAssertNoThrow([host advanceFrame:host.fixedFrameDt]);
}

@end
