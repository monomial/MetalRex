#pragma once
#import <MetalKit/MetalKit.h>
#import "MetaProgressStore.h"
#include "Platform/InputState.h"

typedef NS_ENUM(NSInteger, BrawlerGamePhase) {
    BrawlerGamePhaseTitle        = 0, // title screen — waiting for any button
    BrawlerGamePhasePlayerSelect = 1, // 1 or 2 players?
    BrawlerGamePhasePlaying      = 2, // active combat
    BrawlerGamePhaseRoomClear    = 3, // brief pause between rooms
    BrawlerGamePhaseWin          = 4, // all rooms beaten
    BrawlerGamePhaseLose         = 5, // all lives exhausted
    BrawlerGamePhasePaused       = 6, // mid-game pause
    BrawlerGamePhaseUpgrade      = 7, // pick a perk before the next room
    BrawlerGamePhaseMetaShop     = 8, // persistent upgrades before a run
};

// Shared game delegate used by all three platform targets (macOS, iOS, tvOS).
// Owns the World, renderer, audio, haptics, character loading, and game loop.
// Platform GameViewControllers are thin wrappers that translate input and
// call setInputState: / triggerAttack:.
@interface BrawlerGameDelegate : NSObject <MTKViewDelegate>

- (instancetype)initWithDevice:(id<MTLDevice>)device pixelFormat:(MTLPixelFormat)pfmt;

// Headless init for scenario tests and automation: full game logic and phase
// machine, but no renderer, audio, haptics, or character meshes. All of those
// are nil and every call to them is a no-op (ObjC nil messaging).
- (instancetype)initHeadless;

// Advance game logic by dt seconds: input pulses, simulation, event routing,
// phase state machine. Called by drawInMTKView: each frame; headless drivers
// call it directly with a fixed dt.
- (void)advanceFrame:(float)dt;

// Set the full input state for a specific player (0 = P1, 1 = P2, …).
- (void)setInputState:(InputState)state forPlayer:(int)playerIndex;

// Read back the current state for a player (used by controller handlers that
// update only one field at a time, e.g. thumbstick without touching attack).
- (InputState)currentInputStateForPlayer:(int)playerIndex;

// Convenience shorthands for single-player / P1-only callers.
- (void)setInputState:(InputState)state;
- (InputState)currentInputState;

// Fire a one-frame attack pulse (touch tap, single press). Does not affect
// held-button platforms — those set attack via setInputState: directly.
- (void)triggerAttack;

// Fire a one-frame dodge pulse (touch flick, single press). Same pattern as triggerAttack.
- (void)triggerDodge;

// Fire a one-frame special pulse.
- (void)triggerSpecial;

// Fire a one-frame pause/resume pulse.
- (void)triggerPause;

// Start the game with a specific player count. Call from the player-select UI.
- (void)startGameWithPlayers:(int)playerCount;
- (void)enterMetaShop;
- (void)exitMetaShop;
- (void)metaShopMove:(int)delta;
- (BOOL)buySelectedMetaUpgrade;
- (NSString *)metaShopLine:(int)index;
- (int)currentMetaShopIndex;

// Upgrade phase: label for choice 0 or 1 (shown by the platform overlay).
// In-phase input also picks directly: attack pulse → 0, dodge pulse → 1.
- (NSString *)upgradeChoiceLabel:(int)index;
- (void)chooseUpgrade:(int)index;

// 0-based player index currently choosing an upgrade, or -1 outside Upgrade.
- (int)currentUpgradePlayerIndex;

// Headless-test visibility for post-upgrade exit flow.
- (int)exitEntityCount;
- (int)shopkeeperEntityCount;
- (int)shopItemEntityCount;
- (int)comboCount;
- (int)maxCombo;
- (int)scoreValue;
- (int)debugPerkDamageBonusForPlayer:(int)playerIndex;
- (int)debugPerkMaxHPBonusForPlayer:(int)playerIndex;
- (int)debugPerkLifestealForPlayer:(int)playerIndex;
- (BOOL)debugPerkThornsForPlayer:(int)playerIndex;
- (BOOL)debugPerkWhirlwindForPlayer:(int)playerIndex;
- (BOOL)debugPerkPassiveSpecialForPlayer:(int)playerIndex;
- (float)debugPerkDodgeChanceForPlayer:(int)playerIndex;
- (NSString *)debugPerkLabelForID:(int)perkID;
- (void)debugApplyPerkID:(int)perkID toPlayer:(int)playerIndex;
- (void)debugRegisterEnemyDamage:(int)amount;
- (void)debugRegisterPlayerDamage:(int)amount;
- (void)debugAdvanceComboTimer:(float)dt;
- (BOOL)debugShopItemsHaveDistinctPerks;
- (float)debugCurseMult;
- (int)debugCurseStacks;
- (int)debugRunCoins;
- (int)debugScrap;
- (int)debugFirstPlayerMaxHP;
- (int)debugFirstPlayerSecondWinds;
- (int)debugFirstPlayerDodgeMaxCharges;
- (MetaProgressStore *)debugMetaStore;
- (void)setMetaStoreOverride:(MetaProgressStore *)store;
- (int)debugCursedExitType;
- (int)debugFirstEnemyMaxHP;
- (void)debugForceCurseMult:(float)mult stacks:(int)stacks;
- (void)debugApplyCurseRewardType:(int)curseType;
- (void)debugReloadCurrentRoom;

// Zero all input — call when the app goes to background so held inputs
// don't stay active on resume.
- (void)resetInput;

// Deterministic-run override: when nonzero, every room load seeds the World
// RNG with this value (scenario tests, --autotest). 0 = random seed per room.
@property (nonatomic) uint32_t rngSeedOverride;

// When YES, AutoPilot drives every active player during the Playing phase:
// walk to the nearest enemy, punch in range. Used by scenario tests and the
// --autotest visual smoke mode.
@property (nonatomic) BOOL autoPilotEnabled;

// When > 0, drawInMTKView: advances the simulation by exactly this much per
// frame instead of wall-clock dt. Combined with rngSeedOverride this makes a
// live --autotest run reproduce the headless scenario bit-for-bit (wall-clock
// dt jitter is the only nondeterminism left otherwise).
@property (nonatomic) float fixedFrameDt;

// Write the next rendered frame to a PNG (async). No-op in headless mode.
// Requires the MTKView's framebufferOnly == NO.
- (void)captureNextFrameToPath:(NSString *)path;

// Read-only game state for platform UIs (overlay labels, HUD).
@property (readonly, nonatomic) BrawlerGamePhase gamePhase;
@property (readonly, nonatomic) int currentRoom;    // 1-indexed (1–4)
@property (readonly, nonatomic) int livesRemaining; // 0–3

// Called on the main thread each time the phase transitions.
// room and lives reflect the NEW state after the transition.
@property (copy, nonatomic) void (^onPhaseChanged)(BrawlerGamePhase phase, int room, int lives);

// Called when the player takes damage (survives). Use for screen-flash feedback.
@property (copy, nonatomic) void (^onPlayerDamaged)(void);

@end
