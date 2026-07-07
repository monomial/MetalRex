#import "AudioEngine.h"
#include <math.h>
#include <stdlib.h>

// ---------------------------------------------------------------------------
// Buffer synthesis helpers
// ---------------------------------------------------------------------------

static AVAudioPCMBuffer* synth_buffer(AVAudioFormat *fmt, double durationSec,
                                       void (^fill)(float *L, float *R, int frames, double sr)) {
    int frames = (int)(fmt.sampleRate * durationSec);
    AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:frames];
    buf.frameLength = frames;
    float *L = buf.floatChannelData[0];
    float *R = (fmt.channelCount > 1) ? buf.floatChannelData[1] : nullptr;
    fill(L, R, frames, fmt.sampleRate);
    return buf;
}

// Improved punch impact: low thump + high-freq crack, 2ms fade-in to kill click transient.
static AVAudioPCMBuffer* make_hit_buffer(AVAudioFormat *fmt) {
    return synth_buffer(fmt, 0.18, ^(float *L, float *R, int frames, double sr) {
        for (int i = 0; i < frames; ++i) {
            float t     = (float)i / (float)frames;
            float tSec  = (float)i / (float)sr;
            float attack = fminf(tSec / 0.003f, 1.f);              // 3ms fade-in → no click
            float thump  = sinf(2.f * (float)M_PI * 90.f * tSec)
                           * expf(-tSec * 28.f) * 0.55f;           // 90 Hz body thump
            float noise  = ((float)rand() / (float)RAND_MAX * 2.f - 1.f);
            float crack  = noise * expf(-tSec * 90.f) * 0.22f;     // fast noise crack
            float s      = (thump + crack) * attack;
            L[i] = s;
            if (R) R[i] = s;
        }
    });
}

// Short, slightly higher-pitched impact for when the player takes a hit.
static AVAudioPCMBuffer* make_hurt_buffer(AVAudioFormat *fmt) {
    return synth_buffer(fmt, 0.14, ^(float *L, float *R, int frames, double sr) {
        for (int i = 0; i < frames; ++i) {
            float tSec   = (float)i / (float)sr;
            float attack = fminf(tSec / 0.003f, 1.f);
            float thump  = sinf(2.f * (float)M_PI * 140.f * tSec)
                           * expf(-tSec * 35.f) * 0.45f;
            float noise  = ((float)rand() / (float)RAND_MAX * 2.f - 1.f);
            float crack  = noise * expf(-tSec * 70.f) * 0.18f;
            float s      = (thump + crack) * attack;
            L[i] = s;
            if (R) R[i] = s;
        }
    });
}

// Descending thump with longer tail for enemy/player death.
static AVAudioPCMBuffer* make_death_buffer(AVAudioFormat *fmt) {
    return synth_buffer(fmt, 0.30, ^(float *L, float *R, int frames, double sr) {
        for (int i = 0; i < frames; ++i) {
            float tSec   = (float)i / (float)sr;
            float attack = fminf(tSec / 0.004f, 1.f);
            float freq   = 120.f * expf(-tSec * 4.f);             // pitch drop 120→~18Hz
            // Integrate frequency to get phase (avoid discontinuity in freq sweep)
            // Simple approx: use instantaneous freq
            float phase  = 2.f * (float)M_PI * (120.f / 4.f) * (1.f - expf(-tSec * 4.f));
            float thump  = sinf(phase) * expf(-tSec * 10.f) * 0.55f;
            float noise  = ((float)rand() / (float)RAND_MAX * 2.f - 1.f);
            float rumble = noise * expf(-tSec * 18.f) * 0.20f;
            float s      = (thump + rumble) * attack;
            L[i] = s;
            if (R) R[i] = s;
        }
    });
}

// Quick air whoosh for a punch starting: band-limited noise with a sine sweep,
// quiet enough to sit under the hit impact that may follow.
static AVAudioPCMBuffer* make_swing_buffer(AVAudioFormat *fmt) {
    return synth_buffer(fmt, 0.12, ^(float *L, float *R, int frames, double sr) {
        float lp = 0.f;
        for (int i = 0; i < frames; ++i) {
            float t      = (float)i / (float)frames;
            float tSec   = (float)i / (float)sr;
            float attack = fminf(tSec / 0.005f, 1.f);
            float env    = attack * sinf((float)M_PI * t);          // swell then fade
            float noise  = ((float)rand() / (float)RAND_MAX * 2.f - 1.f);
            lp += 0.25f * (noise - lp);                             // crude low-pass → "air"
            float s = lp * env * 0.30f;
            L[i] = s;
            if (R) R[i] = s;
        }
    });
}

// Longer, airier swish for the dodge roll.
static AVAudioPCMBuffer* make_dodge_buffer(AVAudioFormat *fmt) {
    return synth_buffer(fmt, 0.22, ^(float *L, float *R, int frames, double sr) {
        float lp = 0.f;
        for (int i = 0; i < frames; ++i) {
            float t      = (float)i / (float)frames;
            float tSec   = (float)i / (float)sr;
            float attack = fminf(tSec / 0.008f, 1.f);
            float env    = attack * sinf((float)M_PI * powf(t, 0.7f));
            float noise  = ((float)rand() / (float)RAND_MAX * 2.f - 1.f);
            lp += 0.12f * (noise - lp);                             // darker than swing
            float s = lp * env * 0.32f;
            L[i] = s;
            if (R) R[i] = s;
        }
    });
}

// Combo finisher impact: deeper and louder than the normal hit.
static AVAudioPCMBuffer* make_finisher_buffer(AVAudioFormat *fmt) {
    return synth_buffer(fmt, 0.26, ^(float *L, float *R, int frames, double sr) {
        for (int i = 0; i < frames; ++i) {
            float tSec   = (float)i / (float)sr;
            float attack = fminf(tSec / 0.003f, 1.f);
            float thump  = sinf(2.f * (float)M_PI * 65.f * tSec)
                           * expf(-tSec * 18.f) * 0.75f;            // 65 Hz body slam
            float noise  = ((float)rand() / (float)RAND_MAX * 2.f - 1.f);
            float crack  = noise * expf(-tSec * 70.f) * 0.30f;
            float s      = (thump + crack) * attack;
            L[i] = s;
            if (R) R[i] = s;
        }
    });
}

// Three ascending sine notes for room clear.
static AVAudioPCMBuffer* make_room_clear_buffer(AVAudioFormat *fmt) {
    return synth_buffer(fmt, 0.45, ^(float *L, float *R, int frames, double sr) {
        const float notes[3] = {523.25f, 659.25f, 783.99f}; // C5 E5 G5
        for (int i = 0; i < frames; ++i) {
            float tSec = (float)i / (float)sr;
            int   n    = (int)fminf(tSec / 0.15f, 2.f);
            float nT   = tSec - n * 0.15f;
            float env  = fminf(nT / 0.01f, 1.f) * expf(-nT * 14.f);
            float s    = sinf(2.f * (float)M_PI * notes[n] * nT) * env * 0.30f;
            L[i] = s;
            if (R) R[i] = s;
        }
    });
}

// Tiny 1kHz tick for menu/phase advances.
static AVAudioPCMBuffer* make_ui_click_buffer(AVAudioFormat *fmt) {
    return synth_buffer(fmt, 0.04, ^(float *L, float *R, int frames, double sr) {
        for (int i = 0; i < frames; ++i) {
            float tSec   = (float)i / (float)sr;
            float attack = fminf(tSec / 0.002f, 1.f);
            float s = sinf(2.f * (float)M_PI * 1000.f * tSec)
                      * expf(-tSec * 120.f) * attack * 0.25f;
            L[i] = s;
            if (R) R[i] = s;
        }
    });
}

// ---------------------------------------------------------------------------
// Bundle asset lookup — tries multiple extensions, returns nil if not found.
// ---------------------------------------------------------------------------

static NSURL* bundleAudioURL(NSString *name) {
    NSArray *exts = @[@"wav", @"caf", @"mp3", @"m4a", @"aiff"];
    // Search top-level resources, then the assets/audio subfolder (folder reference).
    NSArray *subdirs = @[@"", @"assets/audio", @"audio"];
    for (NSString *sub in subdirs) {
        NSString *subArg = sub.length ? sub : nil;
        for (NSString *ext in exts) {
            NSURL *url = [[NSBundle mainBundle] URLForResource:name
                                                withExtension:ext
                                                 subdirectory:subArg];
            if (url) return url;
        }
    }
    return nil;
}

// Loads a bundle audio file into an AVAudioPCMBuffer in the engine's format.
// Returns nil if the file is not found or conversion fails.
static AVAudioPCMBuffer* loadBundleBuffer(NSString *name, AVAudioFormat *targetFmt) {
    NSURL *url = bundleAudioURL(name);
    if (!url) return nil;

    NSError *err = nil;
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:url error:&err];
    if (!file) {
        NSLog(@"AudioEngine: failed to open %@: %@", name, err);
        return nil;
    }

    // Convert to engine's processing format if needed.
    AVAudioConverter *conv = [[AVAudioConverter alloc] initFromFormat:file.processingFormat
                                                            toFormat:targetFmt];
    AVAudioFrameCount capacity = (AVAudioFrameCount)(file.length * targetFmt.sampleRate
                                                     / file.processingFormat.sampleRate) + 1024;
    AVAudioPCMBuffer *out = [[AVAudioPCMBuffer alloc] initWithPCMFormat:targetFmt
                                                          frameCapacity:capacity];
    AVAudioPCMBuffer *src = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat
                                                          frameCapacity:(AVAudioFrameCount)file.length];
    if (![file readIntoBuffer:src error:&err]) {
        NSLog(@"AudioEngine: failed to read %@: %@", name, err);
        return nil;
    }

    __block BOOL inputConsumed = NO;
    AVAudioConverterInputBlock inputBlock = ^AVAudioBuffer*(AVAudioPacketCount inNumPackets,
                                                            AVAudioConverterInputStatus *outStatus) {
        if (inputConsumed) { *outStatus = AVAudioConverterInputStatus_NoDataNow; return nil; }
        *outStatus = AVAudioConverterInputStatus_HaveData;
        inputConsumed = YES;
        return src;
    };
    NSError *convErr = nil;
    [conv convertToBuffer:out error:&convErr withInputFromBlock:inputBlock];
    if (convErr) {
        NSLog(@"AudioEngine: conversion failed for %@: %@", name, convErr);
        return nil;
    }

    NSLog(@"AudioEngine: loaded %@ from bundle", name);
    return out;
}

// ---------------------------------------------------------------------------
// AudioEngine
// ---------------------------------------------------------------------------

// One AVAudioPlayerNode can't mix: scheduleBuffer queues buffers back-to-back,
// so rapid combat SFX drift late and stale sounds dribble out after the fight.
// A small round-robin pool plays every sound immediately and lets them overlap.
static const int kNumSfxNodes = 8;

@implementation AudioEngine {
    AVAudioEngine       *_engine;
    AVAudioPlayerNode   *_sfxNodes[kNumSfxNodes];
    int                  _sfxNodeIdx;
    AVAudioPCMBuffer    *_hitBuf;
    AVAudioPCMBuffer    *_hurtBuf;
    AVAudioPCMBuffer    *_deathBuf;
    AVAudioPCMBuffer    *_swingBuf;
    AVAudioPCMBuffer    *_dodgeBuf;
    AVAudioPCMBuffer    *_finisherBuf;
    AVAudioPCMBuffer    *_roomClearBuf;
    AVAudioPCMBuffer    *_uiClickBuf;
    AVAudioPlayer       *_musicPlayer;
    float                _musicVolume;
    BOOL                 _musicPaused;
    BOOL                 _started;
}

- (instancetype)init {
    self = [super init];
    _musicVolume = 0.4f; // music sits under SFX, not over them
    return self;
}

- (void)startupInit {
    if (_started) return;
    // BRAWLER_MUTE=1: skip all audio (engine never starts → SFX no-op; music
    // gated below). Used by scripts/smoke.sh so test runs are silent.
    if (getenv("BRAWLER_MUTE")) { NSLog(@"AudioEngine: muted (BRAWLER_MUTE)"); return; }

    _engine = [[AVAudioEngine alloc] init];

    AVAudioMixerNode *mixer = _engine.mainMixerNode;
    AVAudioFormat    *fmt   = [mixer outputFormatForBus:0];
    for (int i = 0; i < kNumSfxNodes; ++i) {
        _sfxNodes[i] = [[AVAudioPlayerNode alloc] init];
        [_engine attachNode:_sfxNodes[i]];
        [_engine connect:_sfxNodes[i] to:mixer format:fmt];
    }

    NSError *err = nil;
    if (![_engine startAndReturnError:&err]) {
        NSLog(@"AudioEngine: startup failed: %@ — audio disabled", err);
        return;
    }

    // Load each SFX: bundle file overrides synthetic fallback.
    _hitBuf       = loadBundleBuffer(@"sfx_hit",        fmt) ?: make_hit_buffer(fmt);
    _hurtBuf      = loadBundleBuffer(@"sfx_hurt",       fmt) ?: make_hurt_buffer(fmt);
    _deathBuf     = loadBundleBuffer(@"sfx_death",      fmt) ?: make_death_buffer(fmt);
    _swingBuf     = loadBundleBuffer(@"sfx_swing",      fmt) ?: make_swing_buffer(fmt);
    _dodgeBuf     = loadBundleBuffer(@"sfx_dodge",      fmt) ?: make_dodge_buffer(fmt);
    _finisherBuf  = loadBundleBuffer(@"sfx_finisher",   fmt) ?: make_finisher_buffer(fmt);
    _roomClearBuf = loadBundleBuffer(@"sfx_room_clear", fmt) ?: make_room_clear_buffer(fmt);
    _uiClickBuf   = loadBundleBuffer(@"sfx_ui_click",   fmt) ?: make_ui_click_buffer(fmt);

    _started = YES;
    NSLog(@"AudioEngine: ready (sampleRate %.0f Hz)", fmt.sampleRate);
}

// Round-robin over the node pool. stop clears anything the node still holds —
// it's at least 7 sounds old by then, so cutting it is inaudible.
- (void)_playBuffer:(AVAudioPCMBuffer*)buf name:(const char*)name {
    if (!_started || !buf) return;
    // BRAWLER_AUDIO_LOG=1: timestamp every SFX so a mystery sound can be
    // matched against this log — if it isn't here, it's the music.
    static const bool sLog = getenv("BRAWLER_AUDIO_LOG") != nullptr;
    if (sLog) NSLog(@"AudioEngine: SFX %s", name);
    AVAudioPlayerNode *node = _sfxNodes[_sfxNodeIdx];
    _sfxNodeIdx = (_sfxNodeIdx + 1) % kNumSfxNodes;
    [node stop];
    [node scheduleBuffer:buf completionHandler:nil];
    [node play];
}

- (void)playHitSound       { [self _playBuffer:_hitBuf       name:"hit"];        }
- (void)playHurtSound      { [self _playBuffer:_hurtBuf      name:"hurt"];       }
- (void)playDeathSound     { [self _playBuffer:_deathBuf     name:"death"];      }
- (void)playSwingSound     { [self _playBuffer:_swingBuf     name:"swing"];      }
- (void)playDodgeSound     { [self _playBuffer:_dodgeBuf     name:"dodge"];      }
- (void)playFinisherSound  { [self _playBuffer:_finisherBuf  name:"finisher"];   }
- (void)playRoomClearSound { [self _playBuffer:_roomClearBuf name:"room_clear"]; }
- (void)playUIClickSound   { [self _playBuffer:_uiClickBuf   name:"ui_click"];   }

// ---------------------------------------------------------------------------
// Music
// ---------------------------------------------------------------------------

- (void)startBattleMusic {
    if (getenv("BRAWLER_MUTE")) return; // silent test runs
    NSURL *url = bundleAudioURL(@"music_battle");
    if (!url) {
        NSLog(@"AudioEngine: music_battle not found — add music_battle.mp3 to bundle to enable music");
        return;
    }
    if (_musicPlayer && _musicPlayer.playing) return;
    if (_musicPlayer && _musicPaused) {
        [self resumeMusic];
        return;
    }

    NSError *err = nil;
    _musicPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&err];
    if (!_musicPlayer) { NSLog(@"AudioEngine: music load failed: %@", err); return; }
    _musicPlayer.numberOfLoops = -1; // loop forever
    _musicPlayer.volume        = _musicVolume;
    [_musicPlayer prepareToPlay];
    [_musicPlayer play];
    _musicPaused = NO;
    NSLog(@"AudioEngine: music started (%@)", url.lastPathComponent);
}

- (void)pauseMusic {
    if (!_musicPlayer || !_musicPlayer.playing) return;
    [_musicPlayer pause];
    _musicPaused = YES;
}

- (void)resumeMusic {
    if (!_musicPlayer || !_musicPaused) return;
    [_musicPlayer play];
    _musicPaused = NO;
}

- (void)stopMusic {
    [_musicPlayer stop];
    _musicPlayer = nil;
    _musicPaused = NO;
}

- (void)setMusicVolume:(float)volume {
    _musicVolume = volume;
    _musicPlayer.volume = volume;
}

@end
