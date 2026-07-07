#import "HapticsEngine.h"
#import <CoreHaptics/CoreHaptics.h>

@implementation HapticsEngine {
    CHHapticEngine *_engine;
    BOOL            _supported;
}

- (void)startupInit {
    if (_supported) return;

    id<CHHapticDeviceCapability> cap = [CHHapticEngine capabilitiesForHardware];
    if (!cap.supportsHaptics) {
        NSLog(@"HapticsEngine: haptics not supported on this device");
        return;
    }

    NSError *err = nil;
    _engine = [[CHHapticEngine alloc] initAndReturnError:&err];
    if (!_engine) { NSLog(@"HapticsEngine init: %@", err); return; }

    __weak HapticsEngine *weakSelf = self;
    _engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) {
        NSLog(@"HapticsEngine stopped (reason %ld) — restarting", (long)reason);
        HapticsEngine *strong = weakSelf;
        if (strong) [strong->_engine startWithCompletionHandler:nil];
    };
    _engine.resetHandler = ^{
        HapticsEngine *strong = weakSelf;
        if (strong) [strong->_engine startWithCompletionHandler:nil];
    };

    [_engine startWithCompletionHandler:^(NSError *startErr) {
        if (startErr) NSLog(@"HapticsEngine start: %@", startErr);
    }];
    _supported = YES;
}

// Builds and fires a one-off pattern. All public play methods funnel here.
- (void)_playEvents:(NSArray<CHHapticEvent *> *)events {
    if (!_supported) return;
    NSError *err = nil;
    CHHapticPattern *pattern =
        [[CHHapticPattern alloc] initWithEvents:events parameters:@[] error:&err];
    if (!pattern) return;
    id<CHHapticPatternPlayer> player = [_engine createPlayerWithPattern:pattern error:&err];
    [player startAtTime:0 error:nil];
}

static CHHapticEvent* transient(float intensity, float sharpness, double time) {
    CHHapticEventParameter *i =
        [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity
                                                      value:intensity];
    CHHapticEventParameter *s =
        [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness
                                                      value:sharpness];
    return [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient
                                         parameters:@[i, s]
                                       relativeTime:time
                                           duration:0.1];
}

static CHHapticEvent* rumble(float intensity, float sharpness, double time, double duration) {
    CHHapticEventParameter *i =
        [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity
                                                      value:intensity];
    CHHapticEventParameter *s =
        [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness
                                                      value:sharpness];
    return [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                         parameters:@[i, s]
                                       relativeTime:time
                                           duration:duration];
}

// Sharp mid-strength tap: a punch landing.
- (void)playHitHaptic {
    [self _playEvents:@[transient(0.85f, 0.9f, 0)]];
}

// Light tap as the swing starts — feel the punch even when it whiffs.
- (void)playAttackHaptic {
    [self _playEvents:@[transient(0.35f, 0.7f, 0)]];
}

// Finisher: full-strength snap followed by a short body rumble.
- (void)playFinisherHaptic {
    [self _playEvents:@[transient(1.0f, 0.8f, 0),
                        rumble(0.6f, 0.3f, 0.02, 0.18)]];
}

// Dodge: soft, dull pulse — motion, not impact.
- (void)playDodgeHaptic {
    [self _playEvents:@[rumble(0.4f, 0.2f, 0, 0.12)]];
}

// Enemy down: thud + decaying tail.
- (void)playDeathHaptic {
    [self _playEvents:@[transient(0.9f, 0.5f, 0),
                        rumble(0.5f, 0.15f, 0.03, 0.25)]];
}

@end
