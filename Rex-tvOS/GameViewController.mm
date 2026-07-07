#import "GameViewController.h"
#import <MetalKit/MetalKit.h>
#import <GameController/GameController.h>
#import "BrawlerGameDelegate.h"
#import "BrawlerStrings.h"
#include "Platform/InputState.h"

// Maps up to 4 GCControllers to player slots (index = player 0–3, value = controller or nil).
static const int kMaxPlayers = 4;

@implementation GameViewController {
    MTKView             *_mtkView;
    BrawlerGameDelegate *_delegate;
    GCController        *_assignedControllers[kMaxPlayers];
    UIView              *_damageFlashView;
    BOOL                 _left, _right, _up, _down, _attack, _dodge;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    memset(_assignedControllers, 0, sizeof(_assignedControllers));

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    _mtkView = [[MTKView alloc] initWithFrame:self.view.bounds device:device];
    _mtkView.autoresizingMask        = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _mtkView.colorPixelFormat        = MTLPixelFormatBGRA8Unorm;
    _mtkView.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
    [self.view addSubview:_mtkView];

    _delegate = [[BrawlerGameDelegate alloc] initWithDevice:device
                                                pixelFormat:_mtkView.colorPixelFormat];
    [_delegate mtkView:_mtkView drawableSizeWillChange:_mtkView.drawableSize];
    _mtkView.delegate = _delegate;

    // Red edge flash when the player takes a hit.
    _damageFlashView = [[UIView alloc] initWithFrame:self.view.bounds];
    _damageFlashView.userInteractionEnabled = NO;
    _damageFlashView.alpha = 0;
    _damageFlashView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    CAGradientLayer *tvFlashGrad = [CAGradientLayer layer];
    tvFlashGrad.frame = _damageFlashView.bounds;
    tvFlashGrad.startPoint = CGPointMake(0, 0.5);
    tvFlashGrad.endPoint   = CGPointMake(1, 0.5);
    UIColor *tvRed   = [UIColor colorWithRed:0.90 green:0.05 blue:0.05 alpha:0.80];
    UIColor *tvClear = [UIColor colorWithRed:0.90 green:0.05 blue:0.05 alpha:0.0];
    tvFlashGrad.colors    = @[(id)tvRed.CGColor, (id)tvClear.CGColor,
                              (id)tvClear.CGColor, (id)tvRed.CGColor];
    tvFlashGrad.locations = @[@0, @0.22, @0.78, @1.0];
    // CALayer autoresizing masks are macOS-only; sync the sublayer frame when
    // the flash fires instead (the tvOS window never resizes anyway).
    [_damageFlashView.layer addSublayer:tvFlashGrad];
    [self.view addSubview:_damageFlashView];

    __weak GameViewController *weakSelf = self;

    _delegate.onPlayerDamaged = ^{
        GameViewController *vc = weakSelf;
        if (!vc) return;
        vc->_damageFlashView.layer.sublayers.firstObject.frame = vc->_damageFlashView.bounds;
        vc->_damageFlashView.alpha = 1.f;
        [UIView animateWithDuration:0.35 delay:0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{ vc->_damageFlashView.alpha = 0; }
                         completion:nil];
    };

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(_controllerConnected:)
               name:GCControllerDidConnectNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(_controllerDisconnected:)
               name:GCControllerDidDisconnectNotification
             object:nil];
    [GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];

    // Controllers already paired/connected at launch don't re-post the connect
    // notification, so the observer above never sees them. Wire up anything
    // already attached so input works from the title screen without the user
    // having to re-pair the controller.
    for (GCController *ctrl in [GCController controllers])
        [self _attachController:ctrl];
}

- (void)pauseRendering  { [_delegate resetInput]; _mtkView.paused = YES; }
- (void)resumeRendering { _mtkView.paused = NO; }

- (void)releaseGPUResources {
    _mtkView.paused = YES;
    _mtkView.delegate = nil;
    _delegate = nil;
}

// ---------------------------------------------------------------------------
// Controller management
// ---------------------------------------------------------------------------

- (BOOL)canBecomeFirstResponder { return YES; }

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self becomeFirstResponder];
}

- (void)_feedKeyboardInput {
    float mx = (_right ? 1.f : 0.f) - (_left ? 1.f : 0.f);
    float my = (_up    ? 1.f : 0.f) - (_down ? 1.f : 0.f);
    InputState s = { mx, my, (bool)_attack, (bool)_dodge, false, false };
    [_delegate setInputState:s forPlayer:0];
}

- (BOOL)_handleKeyboardPress:(UIPress *)press began:(BOOL)began {
    if (!press.key) return NO;

    UIKeyboardHIDUsage keyCode = press.key.keyCode;
    if (began && _delegate.gamePhase == BrawlerGamePhaseTitle) {
        if (keyCode == UIKeyboardHIDUsageKeyboardQ ||
            keyCode == UIKeyboardHIDUsageKeyboardDownArrow) {
            [_delegate enterMetaShop];
        } else {
            [_delegate triggerAttack];
        }
        return YES;
    }
    if (began && _delegate.gamePhase == BrawlerGamePhaseMetaShop) {
        switch (keyCode) {
            case UIKeyboardHIDUsageKeyboardUpArrow:
            case UIKeyboardHIDUsageKeyboardW:
                [_delegate metaShopMove:-1];
                return YES;
            case UIKeyboardHIDUsageKeyboardDownArrow:
            case UIKeyboardHIDUsageKeyboardS:
                [_delegate metaShopMove:1];
                return YES;
            case UIKeyboardHIDUsageKeyboardSpacebar:
                [_delegate buySelectedMetaUpgrade];
                return YES;
            case UIKeyboardHIDUsageKeyboardQ:
            case UIKeyboardHIDUsageKeyboardEscape:
                [_delegate exitMetaShop];
                return YES;
            default:
                return YES;
        }
    }

    switch (keyCode) {
        case UIKeyboardHIDUsageKeyboardA:
        case UIKeyboardHIDUsageKeyboardLeftArrow:
            _left = began;
            break;
        case UIKeyboardHIDUsageKeyboardD:
        case UIKeyboardHIDUsageKeyboardRightArrow:
            _right = began;
            break;
        case UIKeyboardHIDUsageKeyboardW:
        case UIKeyboardHIDUsageKeyboardUpArrow:
            _up = began;
            break;
        case UIKeyboardHIDUsageKeyboardS:
        case UIKeyboardHIDUsageKeyboardDownArrow:
            _down = began;
            break;
        case UIKeyboardHIDUsageKeyboardSpacebar:
            _attack = began;
            break;
        case UIKeyboardHIDUsageKeyboardQ:
            _dodge = began;
            break;
        case UIKeyboardHIDUsageKeyboardEscape:
            if (began) [_delegate triggerPause];
            return YES;
        case UIKeyboardHIDUsageKeyboard1:
            if (began) [_delegate startGameWithPlayers:1];
            return YES;
        case UIKeyboardHIDUsageKeyboard2:
            if (began) [_delegate startGameWithPlayers:2];
            return YES;
        default:
            return NO;
    }

    [self _feedKeyboardInput];
    return YES;
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    BOOL handled = NO;
    for (UIPress *press in presses)
        handled = [self _handleKeyboardPress:press began:YES] || handled;
    if (!handled) [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    BOOL handled = NO;
    for (UIPress *press in presses)
        handled = [self _handleKeyboardPress:press began:NO] || handled;
    if (!handled) [super pressesEnded:presses withEvent:event];
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    BOOL handled = NO;
    for (UIPress *press in presses)
        handled = [self _handleKeyboardPress:press began:NO] || handled;
    if (!handled) [super pressesCancelled:presses withEvent:event];
}

- (void)_attachController:(GCController *)ctrl {
    if (!ctrl) return;

    // Both the connect notification and the startup enumeration can surface the
    // same controller — don't assign it to a second slot.
    for (int i = 0; i < kMaxPlayers; ++i)
        if (_assignedControllers[i] == ctrl) return;

    int slot = -1;
    for (int i = 0; i < kMaxPlayers; ++i) {
        if (!_assignedControllers[i]) { slot = i; break; }
    }
    if (slot < 0) return;

    _assignedControllers[slot] = ctrl;
    [self _wireController:ctrl toSlot:slot];
}

- (void)_controllerConnected:(NSNotification *)note {
    [self _attachController:note.object];
}

- (void)_controllerDisconnected:(NSNotification *)note {
    GCController *ctrl = note.object;
    for (int i = 0; i < kMaxPlayers; ++i) {
        if (_assignedControllers[i] == ctrl) {
            _assignedControllers[i] = nil;
            [_delegate setInputState:{} forPlayer:i];
            break;
        }
    }
}

- (void)_wireController:(GCController *)ctrl toSlot:(int)slot {
    GCExtendedGamepad *ext = ctrl.extendedGamepad;
    if (ext) {
        __weak GameViewController *weakSelf = self;
        ext.leftThumbstick.valueChangedHandler = ^(GCControllerDirectionPad *pad, float x, float y) {
            GameViewController *vc = weakSelf;
            if (!vc) return;
            InputState s = [vc->_delegate currentInputStateForPlayer:slot];
            s.moveX = x; s.moveY = y;
            [vc->_delegate setInputState:s forPlayer:slot];
        };
        ext.buttonA.valueChangedHandler = ^(GCControllerButtonInput *btn, float val, BOOL pressed) {
            GameViewController *vc = weakSelf;
            if (!vc) return;
            InputState s = [vc->_delegate currentInputStateForPlayer:slot];
            s.attack = pressed;
            [vc->_delegate setInputState:s forPlayer:slot];
        };
        ext.buttonB.valueChangedHandler = ^(GCControllerButtonInput *btn, float val, BOOL pressed) {
            GameViewController *vc = weakSelf;
            if (!vc) return;
            InputState s = [vc->_delegate currentInputStateForPlayer:slot];
            s.dodge = pressed;
            [vc->_delegate setInputState:s forPlayer:slot];
        };
        ext.buttonX.valueChangedHandler = ^(GCControllerButtonInput *btn, float val, BOOL pressed) {
            GameViewController *vc = weakSelf;
            if (!vc) return;
            InputState s = [vc->_delegate currentInputStateForPlayer:slot];
            s.special = pressed;
            [vc->_delegate setInputState:s forPlayer:slot];
        };
        // Options button (☰) = pause/resume. Safe to intercept; no system behavior on tvOS.
        ext.buttonOptions.pressedChangedHandler = ^(GCControllerButtonInput *btn, float val, BOOL pressed) {
            if (!pressed) return; // fire on press only
            GameViewController *vc = weakSelf;
            if (!vc) return;
            [vc->_delegate triggerPause];
        };
        return;
    }
    // Siri Remote (micro-gamepad only, no extended profile) — not supported.
    // Too few buttons to play comfortably; require a proper gamepad.
}

@end
