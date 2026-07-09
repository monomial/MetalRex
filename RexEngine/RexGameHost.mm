#import "RexGameHost.h"
#import <QuartzCore/QuartzCore.h>
#include "Simulation/World.h"
#import "Renderer/RexRenderer.h"

@implementation RexGameHost {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    dispatch_semaphore_t _inFlightSemaphore;
    RexRenderer *_renderer;
    World *_world;
    CFTimeInterval _lastFrameTime;
    InputState _inputs[4];
}

- (instancetype)initWithDevice:(id<MTLDevice>)device pixelFormat:(MTLPixelFormat)pixelFormat {
    self = [super init];
    if (!self) return nil;

    _device = device;
    _commandQueue = [_device newCommandQueue];
    _inFlightSemaphore = dispatch_semaphore_create(3);
    _renderer = [[RexRenderer alloc] initWithDevice:_device pixelFormat:pixelFormat];
    _world = new World();
    _lastFrameTime = CACurrentMediaTime();
    _inputs[0] = {};
    _inputs[1] = {};
    _inputs[2] = {};
    _inputs[3] = {};

    return self;
}

- (instancetype)initHeadless {
    self = [super init];
    if (!self) return nil;

    _world = new World();
    _lastFrameTime = CACurrentMediaTime();
    _inputs[0] = {};
    _inputs[1] = {};
    _inputs[2] = {};
    _inputs[3] = {};

    return self;
}

- (void)dealloc {
    delete _world;
}

- (void)setRngSeedOverride:(uint32_t)rngSeedOverride {
    _rngSeedOverride = rngSeedOverride;
    if (_world && rngSeedOverride != 0) {
        _world->set_seed(rngSeedOverride);
    }
}

- (void)advanceFrame:(float)dt {
    if (!_world) return;
    for (int i = 0; i < 4; ++i) {
        _world->set_input(_inputs[i], i);
    }
    _world->update(dt, dt);
}

- (void)setInputState:(InputState)state forPlayer:(int)playerIndex {
    if (playerIndex < 0 || playerIndex >= 4) return;
    _inputs[playerIndex] = state;
    if (_world) _world->set_input(state, playerIndex);
}

- (InputState)currentInputStateForPlayer:(int)playerIndex {
    return (playerIndex >= 0 && playerIndex < 4) ? _inputs[playerIndex] : InputState{};
}

- (void)setInputState:(InputState)state {
    [self setInputState:state forPlayer:0];
}

- (InputState)currentInputState {
    return [self currentInputStateForPlayer:0];
}

- (void)resetInput {
    for (int i = 0; i < 4; ++i) {
        _inputs[i] = {};
        if (_world) _world->set_input(_inputs[i], i);
    }
}

- (void)captureNextFrameToPath:(NSString*)path {
    [_renderer captureNextFrameToPath:path];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    [_renderer updateDrawableSize:size];
}

- (void)drawInMTKView:(MTKView *)view {
    if (!_renderer || !_commandQueue) return;

    dispatch_semaphore_wait(_inFlightSemaphore, DISPATCH_TIME_FOREVER);
    CFTimeInterval now = CACurrentMediaTime();
    float dt = self.fixedFrameDt > 0.f ? self.fixedFrameDt : (float)(now - _lastFrameTime);
    _lastFrameTime = now;
    if (dt > 0.1f) dt = 0.1f;

    [self advanceFrame:dt];

    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    dispatch_semaphore_t semaphore = _inFlightSemaphore;
    [commandBuffer addCompletedHandler:^(__unused id<MTLCommandBuffer> buffer) {
        dispatch_semaphore_signal(semaphore);
    }];
    [_renderer drawWorld:_world inView:view commandBuffer:commandBuffer];
    [commandBuffer commit];
}

@end
