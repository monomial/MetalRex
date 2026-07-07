#import "GameViewController.h"
#import <MetalKit/MetalKit.h>
#import <GameController/GameController.h>
#import "RexGameHost.h"
#include "Platform/InputState.h"

static const int kMaxPlayers = 4;

@implementation GameViewController {
    MTKView *_mtkView;
    RexGameHost *_host;
    GCController *_assignedControllers[kMaxPlayers];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    memset(_assignedControllers, 0, sizeof(_assignedControllers));

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    _mtkView = [[MTKView alloc] initWithFrame:self.view.bounds device:device];
    _mtkView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _mtkView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    _mtkView.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
    _mtkView.preferredFramesPerSecond = 120;
    [self.view addSubview:_mtkView];

    _host = [[RexGameHost alloc] initWithDevice:device pixelFormat:_mtkView.colorPixelFormat];
    [_host mtkView:_mtkView drawableSizeWillChange:_mtkView.drawableSize];
    _mtkView.delegate = _host;

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

- (void)pauseRendering {
    [_host resetInput];
    _mtkView.paused = YES;
}

- (void)resumeRendering {
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
            _assignedControllers[i] = nil;
            [_host setInputState:{} forPlayer:i];
            break;
        }
    }
}

- (void)_attachController:(GCController *)controller {
    if (!controller) return;
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
    [self _wireController:controller toSlot:slot];
}

- (void)_wireController:(GCController *)controller toSlot:(int)slot {
    GCExtendedGamepad *gamepad = controller.extendedGamepad;
    if (!gamepad) return;

    __weak GameViewController *weakSelf = self;
    gamepad.leftThumbstick.valueChangedHandler = ^(GCControllerDirectionPad *pad, float x, float y) {
        GameViewController *vc = weakSelf;
        if (!vc) return;
        InputState state = [vc->_host currentInputStateForPlayer:slot];
        state.stickX = x;
        state.stickY = y;
        [vc->_host setInputState:state forPlayer:slot];
    };
    gamepad.buttonA.valueChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        GameViewController *vc = weakSelf;
        if (!vc) return;
        InputState state = [vc->_host currentInputStateForPlayer:slot];
        state.fire = pressed;
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

@end
