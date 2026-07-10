#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

// Wraps AVAudioEngine (low-latency SFX) + AVAudioPlayer (background music).
// Must be initialized at app startup to avoid the ~100ms cold-start hitch.
//
// Asset loading: each sound method looks for a corresponding file in the main
// bundle (sfx_hit, sfx_hurt, sfx_death — any of .wav .caf .mp3 .m4a) before
// falling back to a synthetic version.  Drop real files into the assets/audio/
// folder and add them to the Xcode target to replace the synthetics.
//
// Music: startBattleMusic looks for music_battle, then music_battle_1,
// music_battle_2, ... (.mp3 .m4a .wav .caf), and plays whichever it finds
// back to back as a playlist, looping the whole set once the last one ends.
// A single track loops forever on its own, same as before. Silent if none
// are present — add tracks when you have them.
@interface AudioEngine : NSObject

// Call once from game delegate init.
- (void)startupInit;

// Sound effects — safe to call every frame, internally rate-limited.
// Bundle file overrides (sfx_hit, sfx_hurt, sfx_death, sfx_swing, sfx_dodge,
// sfx_finisher, sfx_room_clear, sfx_ui_click, sfx_fire) beat the synthetic
// fallbacks.
- (void)playHitSound;       // punch landing on target
- (void)playHurtSound;      // entity receiving damage but not dying
- (void)playDeathSound;     // entity HP hits 0
- (void)playSwingSound;     // attack clip starts (whoosh, lands or not)
- (void)playFinisherSound;  // combo finisher lands (heavier than hit)
- (void)playDodgeSound;     // dodge roll starts
- (void)playRoomClearSound; // all enemies down (short ascending jingle)
- (void)playUIClickSound;   // menu/phase advance
- (void)playFireSound;      // trigger pulled — gun report, independent of hit/miss

// Background music.
- (void)startBattleMusic;
- (void)pauseMusic;
- (void)resumeMusic;
- (void)stopMusic;
- (void)setMusicVolume:(float)volume; // 0.0–1.0, default 0.6

@end
