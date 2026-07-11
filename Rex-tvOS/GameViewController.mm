#import "GameViewController.h"
#import <MetalKit/MetalKit.h>
#import <GameController/GameController.h>
#import "RexGameHost.h"
#import "Haptics/ControllerRumble.h"
#include "Platform/InputState.h"

static const int kMaxPlayers = 4;

@implementation GameViewController {
    MTKView *_mtkView;
    RexGameHost *_host;
    GCController *_assignedControllers[kMaxPlayers];
    ControllerRumble *_rumble[kMaxPlayers];
    uint32_t _lastShotCount[kMaxPlayers];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    memset(_assignedControllers, 0, sizeof(_assignedControllers));

    [self _setupRenderingIfNeeded];
    [NSTimer scheduledTimerWithTimeInterval:1.0 / 120.0
                                     target:self
                                   selector:@selector(_sampleControllerMotion)
                                   userInfo:nil
                                    repeats:YES];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_controllerConnected:)
                                                 name:GCControllerDidConnectNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_controllerDisconnected:)
                                                 name:GCControllerDidDisconnectNotification
                                               object:nil];
    [GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];

    for (GCController *controller in [GCController controllers]) {
        [self _attachController:controller];
    }
}

// Builds (or rebuilds, after releaseGPUResources tore it down) the device,
// MTKView, and RexGameHost. Safe to call repeatedly — no-ops once _host
// exists. Keeps the same MTKView instance across a background/foreground
// cycle (it's cheap; the GPU-heavy state lives in RexGameHost/RexRenderer)
// so only that gets rebuilt.
- (void)_setupRenderingIfNeeded {
    if (_host) return;

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!_mtkView) {
        _mtkView = [[MTKView alloc] initWithFrame:self.view.bounds device:device];
        _mtkView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _mtkView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
        _mtkView.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
        _mtkView.preferredFramesPerSecond = 120;
        [self.view addSubview:_mtkView];
    } else {
        _mtkView.device = device;
    }

    _host = [[RexGameHost alloc] initWithDevice:device pixelFormat:_mtkView.colorPixelFormat];
    [_host mtkView:_mtkView drawableSizeWillChange:_mtkView.drawableSize];
    _mtkView.delegate = _host;
}

- (void)pauseRendering {
    [_host resetInput];
    _mtkView.paused = YES;
}

// releaseGPUResources tears _host down entirely (see below) rather than
// just pausing, so resuming from that state needs to rebuild it — this used
// to only un-pause an MTKView left with a nil delegate and a nil _host,
// which is exactly why the app came back from the background frozen: no
// delegate meant drawInMTKView: never fired again, forever.
- (void)resumeRendering {
    [self _setupRenderingIfNeeded];
    _mtkView.paused = NO;
}

- (void)releaseGPUResources {
    _mtkView.paused = YES;
    _mtkView.delegate = nil;
    _host = nil;
}

- (void)_controllerConnected:(NSNotification *)note {
    [self _attachController:note.object];
}

- (void)_controllerDisconnected:(NSNotification *)note {
    GCController *controller = note.object;
    for (int i = 0; i < kMaxPlayers; ++i) {
        if (_assignedControllers[i] == controller) {
            if (controller.motion) controller.motion.sensorsActive = NO;
            _assignedControllers[i] = nil;
            _rumble[i] = nil;
            // _lastShotCount[i] is left as-is: World::reticle(i).shotCount
            // doesn't advance while no controller feeds that slot's fire
            // input (see below), so resetting it here would misread the
            // stale-vs-fresh gap as a burst of shots on reconnect.
            [_host setInputState:{} forPlayer:i];
            break;
        }
    }
}

- (void)_attachController:(GCController *)controller {
    if (!controller) return;
    // Only real gamepads claim player slots. The Siri Remote is ALSO a
    // GCController (microGamepad profile, no extendedGamepad) and it's
    // nearly always connected on tvOS — without this check it grabbed
    // slot 0 (Player 1) as a dead slot with no input wiring, pushing the
    // first real gamepad to P2 and the second to P3, whose reticle isn't
    // active — i.e. "two controllers connected but only one recognized."
    // Its motion sensors were also feeding remote wobble into P1's gyro.
    if (!controller.extendedGamepad) return;
    for (int i = 0; i < kMaxPlayers; ++i) {
        if (_assignedControllers[i] == controller) return;
    }

    int slot = -1;
    for (int i = 0; i < kMaxPlayers; ++i) {
        if (!_assignedControllers[i]) {
            slot = i;
            break;
        }
    }
    if (slot < 0) return;

    _assignedControllers[slot] = controller;
    // Light the controller's player indicator so each player can see which
    // reticle is theirs (P1 pink = indicator 1, P2 cyan = indicator 2).
    controller.playerIndex = (GCControllerPlayerIndex)(GCControllerPlayerIndex1 + slot);
    if (controller.motion) {
        controller.motion.sensorsActive = YES;
    }
    _rumble[slot] = [[ControllerRumble alloc] initWithController:controller];
    [self _wireController:controller toSlot:slot];
}

- (void)_wireController:(GCController *)controller toSlot:(int)slot {
    GCExtendedGamepad *gamepad = controller.extendedGamepad;
    if (!gamepad) return;

    __weak GameViewController *weakSelf = self;
    // Left stick, not right: buttonA (fire) and the right stick both sit
    // under the right thumb on a standard layout, making it awkward to hold
    // fire while actively aiming with the stick. Left stick + right-hand
    // trigger splits the two across both thumbs.
    gamepad.leftThumbstick.valueChangedHandler = ^(GCControllerDirectionPad *pad, float x, float y) {
        GameViewController *vc = weakSelf;
        if (!vc) return;
        InputState state = [vc->_host currentInputStateForPlayer:slot];
        state.stickX = x;
        state.stickY = y;
        [vc->_host setInputState:state forPlayer:slot];
    };
    // The press that LAUNCHED the app can leak in here: on tvOS you open
    // the app by pressing this same A/X button on the home screen, and if
    // it's still down when this handler gets wired, the handler sees
    // pressed=YES with the matching release having happened before wiring —
    // never delivered — so fire latched ON with no input at all. That was
    // the "machine gun firing continuously over the black launch screen"
    // bug. Arm fire only once the button has been seen up after wiring;
    // buttons that are up at wiring time (the normal case) arm immediately.
    GCControllerButtonInput *buttonA = gamepad.buttonA;
    __block BOOL fireArmed = !buttonA.isPressed;
    buttonA.valueChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        GameViewController *vc = weakSelf;
        if (!vc) return;
        if (!pressed) fireArmed = YES;
        InputState state = [vc->_host currentInputStateForPlayer:slot];
        state.fire = pressed && fireArmed;
        [vc->_host setInputState:state forPlayer:slot];
    };
    gamepad.buttonB.valueChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        GameViewController *vc = weakSelf;
        if (!vc) return;
        InputState state = [vc->_host currentInputStateForPlayer:slot];
        state.recenter = pressed;
        [vc->_host setInputState:state forPlayer:slot];
    };
    gamepad.buttonOptions.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        GameViewController *vc = weakSelf;
        if (!vc || !pressed) return;
        InputState state = [vc->_host currentInputStateForPlayer:slot];
        state.pause = true;
        [vc->_host setInputState:state forPlayer:slot];
    };
}

- (void)_sampleControllerMotion {
    for (int slot = 0; slot < kMaxPlayers; ++slot) {
        GCController *controller = _assignedControllers[slot];
        if (!controller) continue;
        InputState state = [_host currentInputStateForPlayer:slot];
        GCMotion *motion = controller.motion;
        if (motion && motion.sensorsActive) {
            state.gyroDeltaX = (float)(motion.rotationRate.y * (1.0 / 120.0));
            state.gyroDeltaY = (float)(motion.rotationRate.x * (1.0 / 120.0));
        } else {
            state.gyroDeltaX = 0.f;
            state.gyroDeltaY = 0.f;
        }
        [_host setInputState:state forPlayer:slot];

        // New shots since last poll -> one rumble pulse per shot, same
        // shotCount-diff pattern RexRenderer uses to spawn tracers.
        uint32_t shots = [_host shotCountForPlayer:slot];
        if (shots < _lastShotCount[slot]) {
            // Run restart (play-again zeroes shotCount): resync without
            // phantom rumble pulses from the unsigned wraparound.
            _lastShotCount[slot] = shots;
        } else if (shots != _lastShotCount[slot]) {
            uint32_t newShots = shots - _lastShotCount[slot];
            _lastShotCount[slot] = shots;
            for (uint32_t s = 0; s < newShots && s < 3; ++s) {
                [_rumble[slot] playShootPulse];
            }
        }
    }
}

@end
