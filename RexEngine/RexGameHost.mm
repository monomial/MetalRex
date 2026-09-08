#import "RexGameHost.h"
#import <QuartzCore/QuartzCore.h>
#include "Simulation/World.h"
#include "Simulation/Systems/AutopilotSystem.h"
#include <algorithm>
#include <stdexcept>
#include <cstdio>
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
    BOOL _replayHooksStarted;
    NSException* _replayHookError;
    std::string _recordPath;
    uint64_t _lastSavedTick;
    AutopilotState _autopilotState;
    NSString *_clipDirectory;
    int _clipFramesRemaining;
    int _clipWarmupRemaining;
    int _clipFrameIndex;
    void (^_clipCompletion)(void);
}

- (instancetype)initWithDevice:(id<MTLDevice>)device pixelFormat:(MTLPixelFormat)pixelFormat {
    self = [super init];
    if (!self) return nil;

    _device = device;
    _commandQueue = [_device newCommandQueue];
    _inFlightSemaphore = dispatch_semaphore_create(3);
    _renderer = [[RexRenderer alloc] initWithDevice:_device pixelFormat:pixelFormat];
    _world = new World();
    // Real render path boots to the title screen; players join by pressing
    // fire. That includes --capture-out runs: a plain capture shows the
    // title, and gameplay captures need --auto-fire (whose first pulse
    // joins P1 and starts a solo run). Only initHeadless below — unit
    // tests — constructs straight into a running 2P world.
    // Capture/debug scene hooks (companion to --capture-out / --auto-fire): the
    // constructor already builds a Playing 2P world, so these env vars skip the
    // title to drop a headless screenshot run straight into a specific scene for
    // visual verification. Off by default — real launches still boot to title.
    //   REX_CAPTURE_ARENA=1 : jump into the post-boss holdout (camera stopped,
    //                         ArenaSystem spawns the first wave after its delay).
    //   REX_CAPTURE_PLAY=1  : run the chase from the start with NO auto-fire, so
    //                         pursuers survive across frames (A/B a swerve).
    if (getenv("REX_CAPTURE_ARENA")) {
        _world->enter_arena();
    } else if (getenv("REX_CAPTURE_PLAY")) {
        // Intentionally leave the world in its Playing 2P constructor state.
    } else {
        _world->enter_title();
    }
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
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self _saveRecording];
    delete _world;
}

- (void)setRngSeedOverride:(uint32_t)rngSeedOverride {
    _rngSeedOverride = rngSeedOverride;
    if (_world && rngSeedOverride != 0) {
        _world->set_seed(rngSeedOverride);
    }
}

// Start on the first frame, after capture-mode setup and seed overrides.
- (void)_startReplayHooks {
    if (_replayHooksStarted) {
        if (_replayHookError) @throw _replayHookError;
        return;
    }
    _replayHooksStarted = YES;
    const char* replayPath = getenv("REX_REPLAY");
    const char* recordPath = getenv("REX_RECORD");
    try {
        if (replayPath && recordPath) throw std::runtime_error("REX_RECORD and REX_REPLAY are mutually exclusive");
        if (replayPath) {
            InputRecording log;
            std::string error;
            if (!log.loadFromFile(replayPath, &error)) throw std::runtime_error(error);
            auto integer = [&](const char* field) -> uint64_t {
                auto it = log.header.fields.find(field);
                if (it == log.header.fields.end()) throw std::runtime_error(std::string("replay mismatch: ") + field);
                size_t used = 0;
                uint64_t value;
                try { value = std::stoull(it->second, &used); }
                catch (...) { throw std::runtime_error(std::string("invalid replay field: ") + field); }
                if (used != it->second.size()) throw std::runtime_error(std::string("invalid replay field: ") + field);
                return value;
            };
            // Establish recorded startup state, then begin_replay validates every
            // knob against this build. An explicit caller seed remains authoritative.
            uint64_t seed = integer("seed");
            if (seed > UINT32_MAX) throw std::runtime_error("invalid replay field: seed");
            uint64_t phase = integer("initial.phase");
            if (phase > (int)GamePhase::Playing) throw std::runtime_error("invalid replay field: initial.phase");
            // Reconstruct once from the constructor baseline: enter_title also
            // recreates entities, so calling it twice would change their IDs.
            uint32_t chosenSeed = self.rngSeedOverride ?: (uint32_t)seed;
            delete _world;
            _world = new World();
            _world->set_seed(chosenSeed);
            if (phase == (int)GamePhase::Title) _world->enter_title();
            if (integer("initial.arena") == 1 && !_world->arena_active()) _world->enter_arena();
            for (int p = 0; p < kRexMaxPlayers; ++p) {
                std::string field = "initial.active[" + std::to_string(p) + "]";
                uint64_t active = integer(field.c_str());
                if (active > 1) throw std::runtime_error("invalid replay field: " + field);
                _world->reticle(p).active = active != 0;
            }
            _world->begin_replay(log);
            NSLog(@"REX_REPLAY: loaded %zu ticks from %s", log.tickCount(), replayPath);
        } else if (recordPath) {
            _recordPath = recordPath;
            _world->begin_recording(kRexMaxPlayers); // includes later controller joins
            [self _saveRecording];
            // Flush the final partial second on normal app termination/backgrounding.
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_recordingLifecycle:)
                name:@"NSApplicationWillTerminateNotification" object:nil];
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_recordingLifecycle:)
                name:@"UIApplicationDidEnterBackgroundNotification" object:nil];
        }
    } catch (const std::exception& e) {
        NSLog(@"REPLAY ERROR: %s", e.what());
        _replayHookError = [NSException exceptionWithName:@"RexReplayError"
                                                 reason:[NSString stringWithUTF8String:e.what()] userInfo:nil];
        @throw _replayHookError;
    }
}

- (void)_recordingLifecycle:(NSNotification*)notification {
    (void)notification;
    [self _saveRecording];
}

- (void)_saveRecording {
    if (_recordPath.empty() || !_world || !_world->recording()) return;
    std::string error;
    std::string temporary = _recordPath + ".tmp";
    if (!_world->recording()->saveToFile(temporary.c_str(), &error)
        || std::rename(temporary.c_str(), _recordPath.c_str()) != 0) {
        NSLog(@"REX_RECORD ERROR: %s (%s)", error.empty() ? "could not replace recording" : error.c_str(), _recordPath.c_str());
    } else {
        _lastSavedTick = _world->tick_count();
    }
}

- (void)advanceFrame:(float)dt {
    if (!_world) return;
    [self _startReplayHooks];
    // Composed BEFORE the set_input loop so it goes through the exact same
    // path a controller does — the autopilot is a player, not a back door.
    if (_autopilotEnabled) {
        _inputs[0] = AutopilotSystem_input(*_world, _autopilotState, 0);
    }
    for (int i = 0; i < 4; ++i) {
        _world->set_input(_inputs[i], i);
    }
    _world->update(dt);
    if (!_recordPath.empty() && _world->tick_count() - _lastSavedTick >= 120) [self _saveRecording];
    [self _playAudioCues];
}

// Hit/weak-point/interrupt/hurt all used to trigger a synthesized "thump"
// sound here (see git history) — pulled in favor of visual feedback for
// those moments instead, at least for now. The gunshot report remains one
// per shot fired, independent of hit/miss; raptors vocalise before lunging.
- (void)_playAudioCues {
    if (!_audio || !_world) return;
    AudioCueCounts cues = _world->consume_audio_cues();
    for (int i = 0; i < cues.shotsFired; ++i) [_audio playFireSound];
    // More than two identical buffers layered combs rather than reading as
    // more animals. Keep the truthful per-dino count in the simulation.
    int hurts = std::min(cues.playerHurts, 2);
    for (int i = 0; i < hurts; ++i) [_audio playHurtSound];
    int tells = std::min(cues.raptorTells, 2);
    for (int i = 0; i < tells; ++i) [_audio playRaptorTellSound];
}

- (void)setInputState:(InputState)state forPlayer:(int)playerIndex {
    if (playerIndex < 0 || playerIndex >= 4) return;
    _inputs[playerIndex] = state;
    if (_world) _world->set_input(state, playerIndex);
}

- (InputState)currentInputStateForPlayer:(int)playerIndex {
    return (playerIndex >= 0 && playerIndex < 4) ? _inputs[playerIndex] : InputState{};
}

- (uint32_t)hurtCountForPlayer:(int)playerIndex {
    if (!_world || playerIndex < 0 || playerIndex >= 4) return 0;
    return _world->player_health(playerIndex).hitCount;
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

- (void)startClipCaptureToDirectory:(NSString*)directory
                             frames:(int)frameCount
                                fps:(int)fps
                       warmupFrames:(int)warmupFrames
                         completion:(void (^)(void))completion {
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    _clipDirectory = [directory copy];
    _clipFramesRemaining = frameCount;
    _clipWarmupRemaining = warmupFrames;
    _clipFrameIndex = 0;
    _clipCompletion = [completion copy];
    // The macOS tuning overlay defaults on, and it sat over every frame of
    // the first recorded clip. A clip is for judging the GAME.
    [_renderer setDebugHUDVisible:NO];
    self.fixedFrameDt = 1.f / (float)std::max(1, fps);
    NSLog(@"clip: recording %d frames at %d fps -> %@", frameCount, fps, directory);
}

// Requests the current frame's PNG, and stalls first if the encoder is
// behind. Without the stall a slow encode never slows the render loop (the
// in-flight semaphore is signalled by an earlier completion handler than the
// one that writes the PNG), so staging buffers pile up unbounded — a long
// capture would grow to gigabytes of retained frames.
- (void)_captureClipFrameIfRecording {
    if (!_clipDirectory) return;
    if (_clipWarmupRemaining > 0) { --_clipWarmupRemaining; return; }

    while ([_renderer pendingCaptureWrites] >= 2) usleep(2000);

    ++_clipFrameIndex;
    NSString *path = [_clipDirectory stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"frame-%05d.png", _clipFrameIndex]];
    [_renderer captureNextFrameToPath:path];

    if (--_clipFramesRemaining > 0) return;

    _clipDirectory = nil;
    void (^done)(void) = _clipCompletion;
    _clipCompletion = nil;
    if (!done) return;

    int written = _clipFrameIndex;
    __weak RexGameHost *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        // The last frames' PNGs are written on the Metal completion thread,
        // after the frame that requested them has been presented — so the
        // caller's exit() would otherwise race the final write. (It did:
        // the first clip recorded 599 of 600 frames.)
        RexGameHost *host = weakSelf;
        for (int i = 0; i < 500 && host && [host->_renderer pendingCaptureWrites] > 0; ++i) {
            usleep(10000);
        }
        NSLog(@"clip: %d frames written", written);
        done();
    });
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
    [self _captureClipFrameIfRecording];
    [_renderer drawWorld:_world inView:view commandBuffer:commandBuffer];
    [commandBuffer commit];
}

@end
