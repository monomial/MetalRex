#import <Foundation/Foundation.h>

// Wraps CHHapticEngine. Initialized at startup (not lazily).
// No-op on hardware that doesn't support haptics (guarded by supportsHaptics).
@interface HapticsEngine : NSObject

// Call once from app delegate before first frame.
- (void)startupInit;

// Sharp transient — call on CombatSystem hit contact.
- (void)playHitHaptic;

// Light tap — player's punch starts (felt even when the swing whiffs).
- (void)playAttackHaptic;

// Heavy thud + short rumble — combo finisher lands.
- (void)playFinisherHaptic;

// Soft low pulse — dodge roll starts.
- (void)playDodgeHaptic;

// Long decaying rumble — an enemy goes down.
- (void)playDeathHaptic;

@end
