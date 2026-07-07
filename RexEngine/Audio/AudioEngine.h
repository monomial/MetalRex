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
// Music: startBattleMusic looks for music_battle (.mp3 .m4a .wav .caf).
// Silent if the file is absent — add a track when you have one.
@interface AudioEngine : NSObject

// Call once from game delegate init.
- (void)startupInit;

// Sound effects — safe to call every frame, internally rate-limited.
// Bundle file overrides (sfx_hit, sfx_hurt, sfx_death, sfx_swing, sfx_dodge,
// sfx_finisher, sfx_room_clear, sfx_ui_click) beat the synthetic fallbacks.
- (void)playHitSound;       // punch landing on target
- (void)playHurtSound;      // entity receiving damage but not dying
- (void)playDeathSound;     // entity HP hits 0
- (void)playSwingSound;     // attack clip starts (whoosh, lands or not)
- (void)playFinisherSound;  // combo finisher lands (heavier than hit)
- (void)playDodgeSound;     // dodge roll starts
- (void)playRoomClearSound; // all enemies down (short ascending jingle)
- (void)playUIClickSound;   // menu/phase advance

// Background music.
- (void)startBattleMusic;
- (void)pauseMusic;
- (void)resumeMusic;
- (void)stopMusic;
- (void)setMusicVolume:(float)volume; // 0.0–1.0, default 0.6

@end
