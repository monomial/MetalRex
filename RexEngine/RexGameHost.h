#pragma once
#import <MetalKit/MetalKit.h>
#include "Platform/InputState.h"

@interface RexGameHost : NSObject <MTKViewDelegate>

- (instancetype)initWithDevice:(id<MTLDevice>)device pixelFormat:(MTLPixelFormat)pixelFormat;
- (instancetype)initHeadless;

- (void)advanceFrame:(float)dt;

- (void)captureNextFrameToPath:(NSString*)path;

// Records EVERY drawn frame to <directory>/frame-00001.png onward, then
// calls completion on the main queue. Meant to be assembled into a video by
// scripts/capture-clip.sh.
//
// Sets fixedFrameDt to 1/fps for the duration: each drawn frame then
// advances exactly one frame of sim time no matter how long the PNG encode
// took, so the assembled clip plays back at true speed and is reproducible
// rather than being a recording of how fast this Mac happened to run. The
// loop also stalls itself when PNG writes fall behind (see
// pendingCaptureWrites), which costs wall-clock time and no sim time.
- (void)startClipCaptureToDirectory:(NSString*)directory
                             frames:(int)frameCount
                                fps:(int)fps
                       warmupFrames:(int)warmupFrames
                         completion:(void (^)(void))completion;

// Shows/hides the macOS-only gyro/stick tuning debug overlay (no-op on
// tvOS). See RexRenderer.h.
- (void)toggleDebugHUD;

- (void)setInputState:(InputState)state forPlayer:(int)playerIndex;
- (InputState)currentInputStateForPlayer:(int)playerIndex;
- (void)setInputState:(InputState)state;
- (InputState)currentInputState;
- (void)resetInput;

// Monotonically increasing count of shots player `playerIndex` has fired —
// mirrors ReticleComponent::shotCount, which RexRenderer already diffs
// per-frame to spawn tracers. Platform layers diff this the same way to
// trigger one controller-rumble pulse per shot (see ControllerRumble).
- (uint32_t)shotCountForPlayer:(int)playerIndex;
- (uint32_t)hurtCountForPlayer:(int)playerIndex;

// Demo autopilot (--autopilot): the host composes player 0's input from the
// live world each frame instead of the platform layer's controller/keyboard
// state, so the game plays itself. Used by scripts/capture-clip.sh to record
// a watchable clip, and by AutopilotTests to soak a full act unattended.
// See Simulation/Systems/AutopilotSystem.h.
@property (nonatomic) BOOL autopilotEnabled;

@property (nonatomic) uint32_t rngSeedOverride;
@property (nonatomic) float fixedFrameDt;

@end
