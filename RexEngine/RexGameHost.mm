#import "RexGameHost.h"
#import <QuartzCore/QuartzCore.h>
#include "Simulation/World.h"
#import "Renderer/RexRenderer.h"
#import "Audio/AudioEngine.h"

@implementation RexGameHost {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    dispatch_semaphore_t _inFlightSemaphore;
    RexRenderer *_renderer;
    World *_world;
    CFTimeInterval _lastFrameTime;
    InputState _inputs[4];
    AudioEngine *_audio;
    BOOL _musicStarted;
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

    // Real playback path only — initHeadless (tests, --capture-out automation)
    // stays silent so headless runs don't spin up AVAudioEngine.
    // startupInit here (pre-warms the engine, avoids the first-SFX hitch),
    // but battle music does NOT start until the first frame actually renders
    // (see drawInMTKView:) — this init runs inside viewDidLoad, seconds
    // before anything is on screen on a slow tvOS launch, and music playing
    // over the system's black launch transition read as broken.
    _audio = [[AudioEngine alloc] init];
    [_audio startupInit];

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
    [self _playAudioCues];
}

// Hit/weak-point/interrupt/hurt all used to trigger a synthesized "thump"
// sound here (see git history) — pulled in favor of visual feedback for
// those moments instead, at least for now. Only the gunshot report is left:
// one per shot fired, independent of hit/miss.
- (void)_playAudioCues {
    if (!_audio || !_world) return;
    AudioCueCounts cues = _world->consume_audio_cues();
    for (int i = 0; i < cues.shotsFired; ++i) [_audio playFireSound];
}

- (void)setInputState:(InputState)state forPlayer:(int)playerIndex {
    if (playerIndex < 0 || playerIndex >= 4) return;
    _inputs[playerIndex] = state;
    if (_world) _world->set_input(state, playerIndex);
}

- (InputState)currentInputStateForPlayer:(int)playerIndex {
    return (playerIndex >= 0 && playerIndex < 4) ? _inputs[playerIndex] : InputState{};
}

- (uint32_t)shotCountForPlayer:(int)playerIndex {
    if (!_world || playerIndex < 0 || playerIndex >= 4) return 0;
    return _world->reticle(playerIndex).shotCount;
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

- (void)toggleDebugHUD {
    [_renderer toggleDebugHUD];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    [_renderer updateDrawableSize:size];
}

- (void)drawInMTKView:(MTKView *)view {
    if (!_renderer || !_commandQueue) return;
    // A view can go a beat without a presentable drawable/pass right after
    // it first appears — layout not settled yet, or (seen on tvOS) a
    // system-level scene transition briefly covering the freshly-launched
    // app. advanceFrame used to run unconditionally every call regardless,
    // so the world kept ticking — and playing music/gunfire — for however
    // long that lasted, entirely invisibly. Checked here, before the
    // in-flight semaphore is touched at all, so there's nothing to release
    // on this early return. currentRenderPassDescriptor/currentDrawable are
    // cached per-frame by MTKView, so drawWorld:inView:commandBuffer:
    // re-reading them a moment later is the same pass/drawable, not fresh
    // ones — this isn't a second, competing acquisition.
    if (!view.currentRenderPassDescriptor || !view.currentDrawable) return;

    // First frame that will actually present — start the music here, not in
    // init: init runs inside viewDidLoad, potentially seconds before
    // anything reaches the screen on a slow tvOS launch.
    if (!_musicStarted) {
        _musicStarted = YES;
        [_audio startBattleMusic];
    }

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
