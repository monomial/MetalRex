#pragma once
#import <MetalKit/MetalKit.h>
#include "Platform/InputState.h"

@interface RexGameHost : NSObject <MTKViewDelegate>

- (instancetype)initWithDevice:(id<MTLDevice>)device pixelFormat:(MTLPixelFormat)pixelFormat;
- (instancetype)initHeadless;

- (void)advanceFrame:(float)dt;

- (void)captureNextFrameToPath:(NSString*)path;

// Shows/hides the macOS-only gyro/stick tuning debug overlay (no-op on
// tvOS). See RexRenderer.h.
- (void)toggleDebugHUD;

- (void)setInputState:(InputState)state forPlayer:(int)playerIndex;
- (InputState)currentInputStateForPlayer:(int)playerIndex;
- (void)setInputState:(InputState)state;
- (InputState)currentInputState;
- (void)resetInput;

@property (nonatomic) uint32_t rngSeedOverride;
@property (nonatomic) float fixedFrameDt;

@end
