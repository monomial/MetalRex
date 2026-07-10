#import "ControllerRumble.h"
#import <CoreHaptics/CoreHaptics.h>

@implementation ControllerRumble {
    CHHapticEngine *_engine;
    id<CHHapticPatternPlayer> _shootPlayer;
}

- (instancetype)initWithController:(GCController *)controller {
    self = [super init];
    if (!self) return nil;

    GCDeviceHaptics *haptics = controller.haptics;
    if (!haptics) return self;

    GCHapticsLocality locality = [self _pickLocality:haptics.supportedLocalities];
    if (!locality) return self;

    _engine = [haptics createEngineWithLocality:locality];
    if (!_engine) return self;

    _engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) {
        NSLog(@"ControllerRumble: engine stopped (reason %ld)", (long)reason);
    };
    __weak CHHapticEngine *weakEngine = _engine;
    _engine.resetHandler = ^{
        [weakEngine startWithCompletionHandler:nil];
    };
    [_engine startWithCompletionHandler:^(NSError *startErr) {
        if (startErr) NSLog(@"ControllerRumble: start failed: %@", startErr);
    }];

    NSError *err = nil;
    CHHapticEventParameter *intensity =
        [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity
                                                       value:0.55f];
    CHHapticEventParameter *sharpness =
        [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness
                                                       value:0.8f];
    CHHapticEvent *tap = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient
                                                        parameters:@[intensity, sharpness]
                                                      relativeTime:0];
    CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[tap] parameters:@[] error:&err];
    if (!pattern) {
        NSLog(@"ControllerRumble: pattern init failed: %@", err);
        return self;
    }
    _shootPlayer = [_engine createPlayerWithPattern:pattern error:&err];
    if (!_shootPlayer) NSLog(@"ControllerRumble: player init failed: %@", err);

    return self;
}

// Prefer both-handles rumble — present on DualSense and the closest match to
// DualShock 4's single combined motor pair; fall back to whatever locality
// the controller actually reports rather than assuming one is present.
- (GCHapticsLocality)_pickLocality:(NSSet<GCHapticsLocality> *)supported {
    if ([supported containsObject:GCHapticsLocalityHandles]) return GCHapticsLocalityHandles;
    if ([supported containsObject:GCHapticsLocalityDefault]) return GCHapticsLocalityDefault;
    if ([supported containsObject:GCHapticsLocalityAll]) return GCHapticsLocalityAll;
    return supported.anyObject;
}

- (void)playShootPulse {
    if (!_shootPlayer) return;
    [_shootPlayer startAtTime:0 error:nil];
}

@end
