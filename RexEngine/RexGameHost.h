#pragma once
#import <MetalKit/MetalKit.h>
#include "Platform/InputState.h"

@interface RexGameHost : NSObject <MTKViewDelegate>

- (instancetype)initWithDevice:(id<MTLDevice>)device pixelFormat:(MTLPixelFormat)pixelFormat;
- (instancetype)initHeadless;

- (void)advanceFrame:(float)dt;

- (void)setInputState:(InputState)state forPlayer:(int)playerIndex;
- (InputState)currentInputStateForPlayer:(int)playerIndex;
- (void)setInputState:(InputState)state;
- (InputState)currentInputState;
- (void)resetInput;

@property (nonatomic) uint32_t rngSeedOverride;
@property (nonatomic) float fixedFrameDt;

@end
