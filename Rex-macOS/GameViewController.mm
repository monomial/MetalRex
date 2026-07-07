#import "GameViewController.h"
#import <MetalKit/MetalKit.h>
#import <GameController/GameController.h>
#import "RexGameHost.h"
#include "Platform/InputState.h"

@implementation GameViewController {
    MTKView *_mtkView;
    RexGameHost *_host;
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
    [GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];
}

- (void)_feedKeyboardInput {
    float x = (_right ? 1.f : 0.f) - (_left ? 1.f : 0.f);
    float y = (_up ? 1.f : 0.f) - (_down ? 1.f : 0.f);
    InputState state = { x, y, 0.f, 0.f, (bool)_recenter, (bool)_fire, (bool)_pause };
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
    GCController *controller = note.object;
    GCExtendedGamepad *gamepad = controller.extendedGamepad;
    if (!gamepad) return;

    __weak GameViewController *weakSelf = self;
    gamepad.leftThumbstick.valueChangedHandler = ^(GCControllerDirectionPad *pad, float x, float y) {
        GameViewController *vc = weakSelf;
        if (!vc) return;
        InputState state = [vc->_host currentInputStateForPlayer:1];
        state.stickX = x;
        state.stickY = y;
        [vc->_host setInputState:state forPlayer:1];
    };
    gamepad.buttonA.valueChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        GameViewController *vc = weakSelf;
        if (!vc) return;
        InputState state = [vc->_host currentInputStateForPlayer:1];
        state.fire = pressed;
        [vc->_host setInputState:state forPlayer:1];
    };
    gamepad.buttonB.valueChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        GameViewController *vc = weakSelf;
        if (!vc) return;
        InputState state = [vc->_host currentInputStateForPlayer:1];
        state.recenter = pressed;
        [vc->_host setInputState:state forPlayer:1];
    };
}

@end
