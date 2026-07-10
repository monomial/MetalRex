#import <Foundation/Foundation.h>
#import <GameController/GameController.h>

// Rumbles one GCController's own haptic motors (DualSense/DualShock 4) via
// GCDeviceHaptics — distinct from HapticsEngine, which drives the *local*
// device's Taptic Engine and has no way to reach a paired gamepad. tvOS has
// no local Taptic Engine at all, so this is the only rumble path available
// on Apple TV.
//
// No-op (all methods safe to call, do nothing) if the controller has no
// haptics engine — e.g. Siri Remote, or an Xbox pad, which exposes no gyro
// either per DESIGN.md Constraints.
@interface ControllerRumble : NSObject

- (instancetype)initWithController:(GCController *)controller;

// Short sharp tap — call once per shot fired.
- (void)playShootPulse;

@end
