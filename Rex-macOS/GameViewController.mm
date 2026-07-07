#import "GameViewController.h"
#import <MetalKit/MetalKit.h>
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#import "BrawlerGameDelegate.h"
#import "BrawlerAutoTest.h"
#import "BrawlerStrings.h"
#include "Platform/InputState.h"

@implementation GameViewController {
    MTKView             *_mtkView;
    BrawlerGameDelegate *_delegate;
    BrawlerAutoTest     *_autoTest;
    NSView              *_damageFlashView;
    BOOL _left, _right, _up, _down, _attack, _special;
}

- (void)loadView {
    _mtkView = [[MTKView alloc] initWithFrame:NSMakeRect(0, 0, 960, 720)
                                       device:MTLCreateSystemDefaultDevice()];
    _mtkView.colorPixelFormat        = MTLPixelFormatBGRA8Unorm;
    _mtkView.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
    if ([BrawlerAutoTest isEnabled])
        _mtkView.framebufferOnly = NO; // allow drawable blit for screenshots
    self.view = _mtkView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _delegate = [[BrawlerGameDelegate alloc] initWithDevice:_mtkView.device
                                                pixelFormat:_mtkView.colorPixelFormat];
    [_delegate mtkView:_mtkView drawableSizeWillChange:_mtkView.drawableSize];
    _mtkView.delegate = _delegate;

    // Red flash when the player takes a hit.
    _damageFlashView = [[NSView alloc] initWithFrame:self.view.bounds];
    _damageFlashView.wantsLayer = YES;
    _damageFlashView.layer.opacity = 0;
    _damageFlashView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    CAGradientLayer *macFlashGrad = [CAGradientLayer layer];
    macFlashGrad.frame = _damageFlashView.bounds;
    macFlashGrad.startPoint = CGPointMake(0, 0.5);
    macFlashGrad.endPoint   = CGPointMake(1, 0.5);
    NSColor *macRed   = [NSColor colorWithRed:0.90 green:0.05 blue:0.05 alpha:0.80];
    NSColor *macClear = [NSColor colorWithRed:0.90 green:0.05 blue:0.05 alpha:0.0];
    macFlashGrad.colors    = @[(id)macRed.CGColor, (id)macClear.CGColor,
                               (id)macClear.CGColor, (id)macRed.CGColor];
    macFlashGrad.locations = @[@0, @0.22, @0.78, @1.0];
    macFlashGrad.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    [_damageFlashView.layer addSublayer:macFlashGrad];
    [self.view addSubview:_damageFlashView positioned:NSWindowAbove relativeTo:nil];

    __weak GameViewController *weakSelf = self;

    _delegate.onPlayerDamaged = ^{
        GameViewController *vc = weakSelf;
        if (!vc) return;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        vc->_damageFlashView.layer.opacity = 1.f;
        [CATransaction commit];
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
        fade.fromValue = @1.f;
        fade.toValue   = @0.f;
        fade.duration  = 0.35;
        fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        fade.fillMode  = kCAFillModeForwards;
        fade.removedOnCompletion = NO;
        [vc->_damageFlashView.layer addAnimation:fade forKey:@"damageFlash"];
        vc->_damageFlashView.layer.opacity = 0.f;
    };

    // P1: keyboard — use a local event monitor so key events are captured regardless
    // of which view is first responder (avoids NSTextField stealing focus).
    __weak GameViewController *weakSelfKbd = self;
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent*(NSEvent *event) {
        GameViewController *vc = weakSelfKbd;
        if (!vc) return event;
        // Repeats must be consumed too: a returned key event walks the
        // responder chain, finds no handler, and macOS plays the alert beep —
        // an intermittent "ping" whenever a movement key is held past the
        // key-repeat delay.
        if (event.isARepeat) return nil;
        [vc keyDown:event];
        return nil; // consume — prevents system beep for unhandled keys
    }];
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyUp handler:^NSEvent*(NSEvent *event) {
        GameViewController *vc = weakSelfKbd;
        if (!vc) return event;
        [vc keyUp:event];
        return nil;
    }];
    [NSTimer scheduledTimerWithTimeInterval:1.0/120.0 target:self
                                   selector:@selector(_feedKeyboardInput) userInfo:nil repeats:YES];

    // P2: first connected GCController
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(_controllerConnected:)
               name:GCControllerDidConnectNotification
             object:nil];
    [GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];

    // --autotest: bot plays a full run, screenshots land in --autotest-out.
    if ([BrawlerAutoTest isEnabled]) {
        _autoTest = [[BrawlerAutoTest alloc] initWithDelegate:_delegate];
        [_autoTest start];
    }
}

// ---------------------------------------------------------------------------
// P1 — keyboard
// ---------------------------------------------------------------------------

- (void)_feedKeyboardInput {
    float mx = (_right ? 1.f : 0.f) - (_left ? 1.f : 0.f);
    float my = (_up    ? 1.f : 0.f) - (_down ? 1.f : 0.f);
    InputState s = { mx, my, (bool)_attack, false, false, (bool)_special };
    [_delegate setInputState:s forPlayer:0];
    _attack = NO;
    _special = NO;
}

- (void)keyDown:(NSEvent *)event {
    if (event.isARepeat) return;
    if (_delegate.gamePhase == BrawlerGamePhaseTitle) {
        if (event.keyCode == 12 || event.keyCode == 125) {
            [_delegate enterMetaShop];
            return;
        }
        if (event.keyCode != 53) {
            [_delegate triggerAttack];
            return;
        }
    }
    if (_delegate.gamePhase == BrawlerGamePhaseMetaShop) {
        switch (event.keyCode) {
            case 126: [_delegate metaShopMove:-1]; return; // up
            case 125: [_delegate metaShopMove:1]; return;  // down
            case 49:  [_delegate buySelectedMetaUpgrade]; return;
            case 12:
            case 53:  [_delegate exitMetaShop]; return;
            default: break;
        }
    }
    switch (event.keyCode) {
        case 0:   _left   = YES; break; // A
        case 2:   _right  = YES; break; // D
        case 13:  _up     = YES; break; // W
        case 1:   _down   = YES; break; // S
        case 14:  _special = YES; break;                       // E      — special
        case 123: _left   = YES; break; // ←
        case 124: _right  = YES; break; // →
        case 126: _up     = YES; break; // ↑
        case 125: _down   = YES; break; // ↓
        case 49:  _attack = YES; break;                         // Space  — attack
        case 12:  [_delegate triggerDodge]; break;             // Q      — dodge
        case 53:  [_delegate triggerPause];  break;            // Escape — pause
        case 18:  [_delegate startGameWithPlayers:1]; break;  // 1      — 1 player
        case 19:  [_delegate startGameWithPlayers:2]; break;  // 2      — 2 players
        default: [super keyDown:event];
    }
}

- (void)keyUp:(NSEvent *)event {
    switch (event.keyCode) {
        case 0:   _left  = NO; break;
        case 2:   _right = NO; break;
        case 13:  _up    = NO; break;
        case 1:   _down  = NO; break;
        case 123: _left  = NO; break;
        case 124: _right = NO; break;
        case 126: _up    = NO; break;
        case 125: _down  = NO; break;
        default: [super keyUp:event];
    }
}

// ---------------------------------------------------------------------------
// P2 — first connected GCController (extended gamepad only)
// ---------------------------------------------------------------------------

- (void)_controllerConnected:(NSNotification *)note {
    GCController *ctrl = note.object;
    if (!ctrl) return;
    GCExtendedGamepad *ext = ctrl.extendedGamepad;
    if (!ext) return;

    __weak GameViewController *weakSelf = self;
    ext.leftThumbstick.valueChangedHandler = ^(GCControllerDirectionPad *pad, float x, float y) {
        GameViewController *vc = weakSelf;
        if (!vc) return;
        InputState s = [vc->_delegate currentInputStateForPlayer:1];
        s.moveX = x; s.moveY = y;
        [vc->_delegate setInputState:s forPlayer:1];
    };
    ext.buttonA.valueChangedHandler = ^(GCControllerButtonInput *btn, float val, BOOL pressed) {
        GameViewController *vc = weakSelf;
        if (!vc) return;
        InputState s = [vc->_delegate currentInputStateForPlayer:1];
        s.attack = pressed;
        [vc->_delegate setInputState:s forPlayer:1];
    };
    ext.buttonX.valueChangedHandler = ^(GCControllerButtonInput *btn, float val, BOOL pressed) {
        GameViewController *vc = weakSelf;
        if (!vc) return;
        InputState s = [vc->_delegate currentInputStateForPlayer:1];
        s.special = pressed;
        [vc->_delegate setInputState:s forPlayer:1];
    };
}

@end
