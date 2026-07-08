#import "GameViewController.h"
#import <MetalKit/MetalKit.h>
#import <GameController/GameController.h>
#import "RexGameHost.h"
#include "Simulation/Systems/ReticleSystem.h"
#include "Platform/InputState.h"

@implementation GameViewController {
    MTKView *_mtkView;
    RexGameHost *_host;
    GCController *_controller;
    BOOL _left, _right, _up, _down, _fire, _recenter, _pause;
}

- (void)loadView {
    _mtkView = [[MTKView alloc] initWithFrame:NSMakeRect(0, 0, 960, 720)
                                       device:MTLCreateSystemDefaultDevice()];
    _mtkView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    _mtkView.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
    _mtkView.preferredFramesPerSecond = 120;
    self.view = _mtkView;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    _host = [[RexGameHost alloc] initWithDevice:_mtkView.device
                                    pixelFormat:_mtkView.colorPixelFormat];
    [_host mtkView:_mtkView drawableSizeWillChange:_mtkView.drawableSize];
    _mtkView.delegate = _host;

    __weak GameViewController *weakSelf = self;
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent*(NSEvent *event) {
        GameViewController *vc = weakSelf;
        if (!vc) return event;
        if (event.isARepeat) return nil;
        [vc keyDown:event];
        return nil;
    }];
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyUp handler:^NSEvent*(NSEvent *event) {
        GameViewController *vc = weakSelf;
        if (!vc) return event;
        [vc keyUp:event];
        return nil;
    }];
    [NSTimer scheduledTimerWithTimeInterval:1.0 / 120.0
                                     target:self
                                   selector:@selector(_feedKeyboardInput)
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

- (void)_feedKeyboardInput {
    float x = (_right ? 1.f : 0.f) - (_left ? 1.f : 0.f);
    float y = (_up ? 1.f : 0.f) - (_down ? 1.f : 0.f);
    InputState state = [_host currentInputStateForPlayer:0];
    if (!_controller || _left || _right || _up || _down) {
        state.stickX = x;
        state.stickY = y;
    }
    state.recenter = state.recenter || (bool)_recenter;
    state.fire = state.fire || (bool)_fire;
    state.pause = state.pause || (bool)_pause;

    GCMotion *motion = _controller.motion;
    if (motion && motion.sensorsActive) {
        state.gyroDeltaX = (float)(motion.rotationRate.y * (1.0 / 120.0));
        state.gyroDeltaY = (float)(-motion.rotationRate.x * (1.0 / 120.0));
    } else {
        state.gyroDeltaX = 0.f;
        state.gyroDeltaY = 0.f;
    }
    [_host setInputState:state forPlayer:0];
    _fire = NO;
    _recenter = NO;
    _pause = NO;
}

- (void)keyDown:(NSEvent *)event {
    if (event.isARepeat) return;
    switch (event.keyCode) {
        case 0:   _left = YES; break;
        case 2:   _right = YES; break;
        case 13:  _up = YES; break;
        case 1:   _down = YES; break;
        case 123: _left = YES; break;
        case 124: _right = YES; break;
        case 126: _up = YES; break;
        case 125: _down = YES; break;
        case 49:  _fire = YES; break;
        case 12:  _recenter = YES; break;
        case 53:  _pause = YES; break;
        case 24:  ReticleSystem_adjust_tuning( 0.05f,  0.00f,  0.00f); break; // =
        case 27:  ReticleSystem_adjust_tuning(-0.05f,  0.00f,  0.00f); break; // -
        case 30:  ReticleSystem_adjust_tuning( 0.00f,  0.03f,  0.00f); break; // ]
        case 33:  ReticleSystem_adjust_tuning( 0.00f, -0.03f,  0.00f); break; // [
        case 39:  ReticleSystem_adjust_tuning( 0.00f,  0.00f,  0.04f); break; // '
        case 41:  ReticleSystem_adjust_tuning( 0.00f,  0.00f, -0.04f); break; // ;
        case 35:  ReticleSystem_adjust_fallback_tuning( 0.05f,  0.00f,  0.00f); break; // P — fallback friction scale up
        case 31:  ReticleSystem_adjust_fallback_tuning(-0.05f,  0.00f,  0.00f); break; // O — fallback friction scale down
        case 47:  ReticleSystem_adjust_fallback_tuning( 0.00f,  0.01f,  0.00f); break; // . — fallback magnet radius up
        case 43:  ReticleSystem_adjust_fallback_tuning( 0.00f, -0.01f,  0.00f); break; // , — fallback magnet radius down
        case 46:  ReticleSystem_adjust_fallback_tuning( 0.00f,  0.00f,  0.03f); break; // M — fallback magnet strength up
        case 45:  ReticleSystem_adjust_fallback_tuning( 0.00f,  0.00f, -0.03f); break; // N — fallback magnet strength down
        default: [super keyDown:event];
    }
}

- (void)keyUp:(NSEvent *)event {
    switch (event.keyCode) {
        case 0:   _left = NO; break;
        case 2:   _right = NO; break;
        case 13:  _up = NO; break;
        case 1:   _down = NO; break;
        case 123: _left = NO; break;
        case 124: _right = NO; break;
        case 126: _up = NO; break;
        case 125: _down = NO; break;
        default: [super keyUp:event];
    }
}

- (void)_controllerConnected:(NSNotification *)note {
    [self _attachController:note.object];
}

- (void)_controllerDisconnected:(NSNotification *)note {
    GCController *controller = note.object;
    if (_controller != controller) return;
    if (_controller.motion) _controller.motion.sensorsActive = NO;
    _controller = nil;
    [_host setInputState:{} forPlayer:0];
}

- (void)_attachController:(GCController *)controller {
    if (!controller || _controller == controller) return;
    _controller = controller;
    if (_controller.motion) {
        _controller.motion.sensorsActive = YES;
    }
    GCExtendedGamepad *gamepad = controller.extendedGamepad;
    if (!gamepad) return;

    __weak GameViewController *weakSelf = self;
    gamepad.rightThumbstick.valueChangedHandler = ^(GCControllerDirectionPad *pad, float x, float y) {
        GameViewController *vc = weakSelf;
        if (!vc) return;
        InputState state = [vc->_host currentInputStateForPlayer:0];
        state.stickX = x;
        state.stickY = y;
        [vc->_host setInputState:state forPlayer:0];
    };
    gamepad.buttonA.valueChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        GameViewController *vc = weakSelf;
        if (!vc) return;
        InputState state = [vc->_host currentInputStateForPlayer:0];
        state.fire = pressed;
        [vc->_host setInputState:state forPlayer:0];
    };
    gamepad.buttonB.valueChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        GameViewController *vc = weakSelf;
        if (!vc) return;
        InputState state = [vc->_host currentInputStateForPlayer:0];
        state.recenter = pressed;
        [vc->_host setInputState:state forPlayer:0];
    };
}

@end
