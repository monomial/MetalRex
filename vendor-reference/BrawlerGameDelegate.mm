#import "BrawlerGameDelegate.h"
#import <MetalKit/MetalKit.h>
#import "BrawlerStrings.h"
#import "MetaProgressStore.h"
#include "Simulation/World.h"
#include "Simulation/AutoPilot.h"
#include "Simulation/Systems/AnimationSystem.h"
#include "Simulation/Systems/WaveSystem.h"
#include "Simulation/Systems/ScreenShakeSystem.h"
#include "Simulation/RoomBounds.h"
#include "Assets/CharacterLoader.h"
#import "Renderer/BrawlerRenderer.h"
#import "Haptics/HapticsEngine.h"
#import "Audio/AudioEngine.h"

// ---------------------------------------------------------------------------
// Room definitions — spawn lists of {archetype, wave, x, y}. HP/speed/scale come
// from the archetype table (Simulation/EnemyArchetypes.h).
// ---------------------------------------------------------------------------
struct EnemySpawn {
    EnemyArchetype type;
    uint8_t wave;
    float x, y;
};

struct ObstacleSpawn {
    float x, y;
    float halfW, halfH;
};

struct BoxSpawn {
    float x, y;
    bool hasScrap;
};

struct RoomDef {
    const EnemySpawn* spawns;
    int               count;
    const ObstacleSpawn* obstacles;
    int               obstacleCount;
    const BoxSpawn*   boxes;
    int               boxCount;
    bool              isShop;
};

// Run structure: fixed intro room, then kMiddlePerRun of the middle pool in a
// seeded-shuffled order, single boss, then twin-boss finale.
static const EnemySpawn kIntroSpawns[] = {
    {EnemyArchetype::Grunt,  0, -140, 350},
    {EnemyArchetype::Grunt,  0,  140, 350},
    {EnemyArchetype::Grunt,  1, -200, 250},
    {EnemyArchetype::Grunt,  1,  200, 250},
};
static const EnemySpawn kMidGruntsRusher[] = {
    {EnemyArchetype::Grunt,  0, -260, 300},
    {EnemyArchetype::Grunt,  0,    0, 360},
    {EnemyArchetype::Rusher, 0,  260, 300},
    {EnemyArchetype::Grunt,  1, -220, 430},
    {EnemyArchetype::Leaper, 1,    0, 500},
    {EnemyArchetype::Spitter,1,  220, 430},
};
static const EnemySpawn kMidRusherPack[] = {
    {EnemyArchetype::Rusher, 0, -250, 380},
    {EnemyArchetype::Rusher, 0,    0, 330},
    {EnemyArchetype::Rusher, 0,  250, 380},
    {EnemyArchetype::Rusher, 1, -160, 450},
    {EnemyArchetype::Rusher, 1,  160, 450},
    {EnemyArchetype::Spitter,1,    0, 520},
};
static const EnemySpawn kMidHeavyEscort[] = {
    {EnemyArchetype::Grunt,  0, -260, 420},
    {EnemyArchetype::Grunt,  0,    0, 360},
    {EnemyArchetype::Spitter,0,  260, 420},
    {EnemyArchetype::Heavy,  1, -180, 320},
    {EnemyArchetype::Rusher, 1,  180, 320},
    {EnemyArchetype::Spitter,1,    0, 510},
};
static const EnemySpawn kMidMixed[] = {
    {EnemyArchetype::Rusher, 0, -250, 380},
    {EnemyArchetype::Grunt,  0,    0, 180},
    {EnemyArchetype::Rusher, 0,  250, 380},
    {EnemyArchetype::Heavy,  1, -150, 300}, // clear of the (0,320) pillar
    {EnemyArchetype::Leaper, 1,  180, 460},
    {EnemyArchetype::Spitter,1,    0, 520},
};
static const EnemySpawn kMidTwinHeavies[] = {
    {EnemyArchetype::Heavy,  0, -180, 320},
    {EnemyArchetype::Grunt,  0,    0, 470},
    {EnemyArchetype::Leaper, 0,  180, 420},
    {EnemyArchetype::Heavy,  1,  120, 320},
    {EnemyArchetype::Rusher, 1, -260, 400},
    {EnemyArchetype::Spitter,1,    0, 520},
};
static const EnemySpawn kBossSpawns[] = {
    {EnemyArchetype::Boss,   0,    0, 350},
};
static const EnemySpawn kFinalSpawns[] = {
    {EnemyArchetype::Boss,   0, -220, 350},
    {EnemyArchetype::Boss,   0,  220, 350},
};
static const EnemySpawn kBossReinforcements[] = {
    {EnemyArchetype::Grunt,  0, -260, 330},
    {EnemyArchetype::Rusher, 0,  260, 330},
    {EnemyArchetype::Spitter,0,    0, 520},
};
static const ObstacleSpawn kHeavyEscortObstacles[] = {
    {-300.f, 150.f, 30.f, 30.f},
    { 300.f, 150.f, 30.f, 30.f},
};
static const ObstacleSpawn kMixedObstacles[] = {
    {0.f, 320.f, 35.f, 35.f},
};

static const BoxSpawn kIntroBoxes[] = {
    {-360.f,  70.f, true}, { 360.f,  90.f, false}, { 0.f, 560.f, true},
};
static const BoxSpawn kGruntsBoxes[] = {
    {-410.f, 180.f, true}, {390.f, 180.f, true}, {-320.f, 560.f, false},
};
static const BoxSpawn kRusherBoxes[] = {
    {-420.f, 120.f, false}, {420.f, 140.f, true}, {0.f, 610.f, true},
};
static const BoxSpawn kHeavyBoxes[] = {
    {-410.f, 240.f, true}, {410.f, 240.f, false}, {-120.f, 600.f, true}, {230.f, 590.f, false},
};
static const BoxSpawn kMixedBoxes[] = {
    {-420.f, 130.f, true}, {420.f, 130.f, false}, {-330.f, 590.f, true},
};
static const BoxSpawn kTwinBoxes[] = {
    {-430.f, 170.f, false}, {430.f, 170.f, true}, {0.f, 610.f, true},
};
static const BoxSpawn kBossBoxes[] = {
    {-420.f, 170.f, true}, {420.f, 170.f, false},
};
static const BoxSpawn kShopBoxes[] = {
    {-360.f, 320.f, true}, {360.f, 320.f, false}, {0.f, 560.f, true},
};

static const RoomDef kIntroRoom = {kIntroSpawns, 4, nullptr, 0, kIntroBoxes, 3, false};
static const RoomDef kBossRoom  = {kBossSpawns, 1, nullptr, 0, kBossBoxes, 2, false};
static const RoomDef kFinalRoom = {kFinalSpawns, 2, nullptr, 0, kBossBoxes, 2, false};
static const RoomDef kShopRoom  = {nullptr, 0, nullptr, 0, kShopBoxes, 3, true};
static const RoomDef kMiddleRooms[] = {
    {kMidGruntsRusher, 6, nullptr, 0, kGruntsBoxes, 3, false},
    {kMidRusherPack,   6, nullptr, 0, kRusherBoxes, 3, false},
    {kMidHeavyEscort,  6, kHeavyEscortObstacles, 2, kHeavyBoxes, 4, false},
    {kMidMixed,        6, kMixedObstacles, 1, kMixedBoxes, 3, false},
    {kMidTwinHeavies,  6, nullptr, 0, kTwinBoxes, 3, false},
};
static const int kNumMiddleRooms = 5;
static const int kMiddlePerRun   = 4;                  // middle rooms per run
static const int kShopRoomIndex  = 3;                  // 0-based: after two middles
static const int kNumRooms       = kMiddlePerRun + 4;  // intro + middles + shop + boss + final
static const int kStartingLives  = 3;
static const int kMaxPlayers     = 4;
static const int kCurseTypeCount = 4;

// Phase timers (seconds).
static const float kRoomClearDuration = 2.0f;
static const float kWinDuration       = 5.0f;
static const float kLoseDuration      = 3.5f;
static const float kUpgradeGrace      = 0.35f; // ignore held buttons right after entering Upgrade
static const int kMetaUpgradeCount    = 4;

typedef NS_ENUM(int, BrawlerMetaUpgrade) {
    BrawlerMetaUpgradeVitality = 0,
    BrawlerMetaUpgradeExtraLife,
    BrawlerMetaUpgradeProspector,
    BrawlerMetaUpgradeResolve,
};

// ---------------------------------------------------------------------------
// Perk pool — two distinct picks are offered between rooms; the chosen perk
// folds into that player's run-level PlayerPerks and is re-applied at each
// spawn (the World is rebuilt per room, so entities can't carry run state).
// Lives are team-level because lives are currently shared by the run.
// ---------------------------------------------------------------------------
typedef NS_ENUM(int, BrawlerPerk) {
    BrawlerPerkDamage = 0,
    BrawlerPerkSpeed,
    BrawlerPerkMaxHP,
    BrawlerPerkLife,
    BrawlerPerkKnockback,
    BrawlerPerkQuickDodge,
    BrawlerPerkSpecialCharge,
    BrawlerPerkSecondWind,
    BrawlerPerkHeavyHitter,
    BrawlerPerkToughness,
    BrawlerPerkLifesteal,
    BrawlerPerkThorns,
    BrawlerPerkWhirlwind,
    BrawlerPerkAdrenaline,
    BrawlerPerkVampire,
    BrawlerPerkEvasion,
    BrawlerPerkDodgeChance,
    BrawlerPerkCount
};

typedef NS_ENUM(int, BrawlerPerkRarity) {
    BrawlerRarityCommon = 0,
    BrawlerRarityRare   = 1,
    BrawlerRarityEpic   = 2,
};

static NSString *const kPerkLabels[BrawlerPerkCount] = {
    @"+1 Punch Damage",
    @"+20% Move Speed",
    @"+3 Max Health",
    @"+1 Team Life",
    @"+30% Knockback",
    @"Quick Dash",
    @"+50% Special Charge",
    @"Second Wind",
    @"Heavy Hitter",
    @"Toughness",
    @"Lifesteal",
    @"Thorns",
    @"Whirlwind",
    @"Adrenaline",
    @"Vampire",
    @"Extra Dash",
    @"Dodge",
};

static const BrawlerPerkRarity kPerkRarity[BrawlerPerkCount] = {
    BrawlerRarityCommon,
    BrawlerRarityCommon,
    BrawlerRarityCommon,
    BrawlerRarityCommon,
    BrawlerRarityCommon,
    BrawlerRarityCommon,
    BrawlerRarityCommon,
    BrawlerRarityCommon,
    BrawlerRarityRare,
    BrawlerRarityRare,
    BrawlerRarityRare,
    BrawlerRarityRare,
    BrawlerRarityEpic,
    BrawlerRarityEpic,
    BrawlerRarityEpic,
    BrawlerRarityRare,
    BrawlerRarityRare,
};

struct PlayerPerks {
    int   bonusDamage = 0;
    float speedMult   = 1.f;
    int   bonusMaxHP  = 0;
    float knockbackMult = 1.f;
    float dodgeCooldownMult = 1.f;
    float dodgeChance = 0.f;
    float specialChargeMult = 1.f;
    int   secondWinds = 0;
    int   lifestealPerHits = 0;
    bool  thorns = false;
    bool  whirlwind = false;
    bool  passiveSpecial = false;
    int   bonusDodgeCharges = 0;
    uint8_t counts[BrawlerPerkCount] = {};
};

struct RunStats {
    int enemiesDefeated = 0;
    int damageDealt     = 0;
    int damageTaken     = 0;
    int heartsCollected = 0;
    int specialsUsed    = 0;
    int perksTaken      = 0;
    int maxCombo        = 0;
    int score           = 0;
    float runTime       = 0.f;
};

static NSString *rarity_prefix(BrawlerPerk perk) {
    if (perk < 0 || perk >= BrawlerPerkCount) return @"";
    switch (kPerkRarity[perk]) {
        case BrawlerRarityRare: return @"★ ";
        case BrawlerRarityEpic: return @"★★ ";
        case BrawlerRarityCommon: return @"";
    }
    return @"";
}

static int rarity_price(BrawlerPerk perk) {
    if (perk < 0 || perk >= BrawlerPerkCount) return 25;
    switch (kPerkRarity[perk]) {
        case BrawlerRarityRare: return 40;
        case BrawlerRarityEpic: return 60;
        case BrawlerRarityCommon: return 25;
    }
    return 25;
}

static float curse_factor(uint8_t curseType) {
    return (curseType == 3) ? 1.2f : 1.1f;
}

static int curse_coin_reward(uint8_t curseType, int stacksTakenSoFar) {
    int coins = 8 + 4 * stacksTakenSoFar;
    if (curseType == 3) coins *= 2;
    return coins;
}

static int meta_level_for_upgrade(MetaProgressStore *store, BrawlerMetaUpgrade upgrade) {
    switch (upgrade) {
        case BrawlerMetaUpgradeVitality:   return store.hpLevel;
        case BrawlerMetaUpgradeExtraLife:  return store.livesLevel;
        case BrawlerMetaUpgradeProspector: return store.scrapLevel;
        case BrawlerMetaUpgradeResolve:    return store.secondWindLevel;
    }
    return 0;
}

static int meta_max_level(BrawlerMetaUpgrade upgrade) {
    switch (upgrade) {
        case BrawlerMetaUpgradeVitality:   return 4;
        case BrawlerMetaUpgradeExtraLife:  return 2;
        case BrawlerMetaUpgradeProspector: return 3;
        case BrawlerMetaUpgradeResolve:    return 1;
    }
    return 0;
}

static int meta_cost(BrawlerMetaUpgrade upgrade, int level) {
    static const int vitality[] = {20, 35, 55, 80};
    static const int lives[] = {60, 120};
    static const int scrap[] = {15, 25, 40};
    static const int resolve[] = {100};
    switch (upgrade) {
        case BrawlerMetaUpgradeVitality:   return (level >= 0 && level < 4) ? vitality[level] : 0;
        case BrawlerMetaUpgradeExtraLife:  return (level >= 0 && level < 2) ? lives[level] : 0;
        case BrawlerMetaUpgradeProspector: return (level >= 0 && level < 3) ? scrap[level] : 0;
        case BrawlerMetaUpgradeResolve:    return (level == 0) ? resolve[0] : 0;
    }
    return 0;
}

static NSString *meta_name(BrawlerMetaUpgrade upgrade) {
    switch (upgrade) {
        case BrawlerMetaUpgradeVitality:   return @"Vitality";
        case BrawlerMetaUpgradeExtraLife:  return @"Extra Life";
        case BrawlerMetaUpgradeProspector: return @"Prospector";
        case BrawlerMetaUpgradeResolve:    return @"Resolve";
    }
    return @"Upgrade";
}

static NSString *meta_effect(BrawlerMetaUpgrade upgrade) {
    switch (upgrade) {
        case BrawlerMetaUpgradeVitality:   return @"+1 HP";
        case BrawlerMetaUpgradeExtraLife:  return @"+1 life";
        case BrawlerMetaUpgradeProspector: return @"+15 scrap";
        case BrawlerMetaUpgradeResolve:    return @"+1 second wind";
    }
    return @"";
}

// ---------------------------------------------------------------------------

@implementation BrawlerGameDelegate {
    World                _world;
    CFTimeInterval       _lastTime;
    id<MTLCommandQueue>  _commandQueue;
    BrawlerRenderer     *_renderer;
    HapticsEngine       *_haptics;
    AudioEngine         *_audio;
    dispatch_semaphore_t _frameSemaphore;
    BOOL                 _attackPulse;
    BOOL                 _dodgePulse;
    BOOL                 _pausePulse;
    BOOL                 _specialPulse;
    int                  _numPlayers; // 1 or 2; set at player-select, remembered between runs

    BrawlerGamePhase     _phase;
    float                _phaseTimer;
    int                  _currentRoom;  // 0-indexed internally
    int                  _lives;

    PlayerPerks          _perks[kMaxPlayers]; // per-player run-level, reset each run
    RunStats             _runStats;
    int                  _scrap;
    float                _curseMult;
    int                  _curseStacks;
    int                  _runCoins;
    BOOL                 _runCoinsBanked;
    MetaProgressStore   *_metaStore;
    int                  _metaShopIndex;
    int                  _combo;
    float                _comboTimer;
    int                  _upgradePlayerIndex; // active picker during Upgrade, -1 otherwise
    int                  _upgradeChoice[2];   // BrawlerPerk indices on offer
    int                  _middleOrder[kNumMiddleRooms]; // seeded shuffle per run
}

@synthesize onPhaseChanged;

- (BrawlerGamePhase)gamePhase    { return _phase; }
- (int)currentRoom               { return _currentRoom + 1; } // 1-indexed for UI
- (int)livesRemaining            { return _lives; }
- (int)currentUpgradePlayerIndex { return (_phase == BrawlerGamePhaseUpgrade) ? _upgradePlayerIndex : -1; }
- (int)comboCount                { return _combo; }
- (int)maxCombo                  { return _runStats.maxCombo; }
- (int)scoreValue                { return _runStats.score; }

- (int)exitEntityCount {
    int count = 0;
    for (EntityID id = 0; id < _world.entity_count(); ++id)
        if (_world.exits().present(id)) count++;
    return count;
}

- (int)shopkeeperEntityCount {
    int count = 0;
    for (EntityID id = 0; id < _world.entity_count(); ++id)
        if (_world.shopkeepers().present(id)) count++;
    return count;
}

- (int)shopItemEntityCount {
    int count = 0;
    for (EntityID id = 0; id < _world.entity_count(); ++id)
        if (_world.shop_items().present(id)) count++;
    return count;
}

- (int)debugPerkDamageBonusForPlayer:(int)playerIndex {
    if (playerIndex < 0 || playerIndex >= kMaxPlayers) return 0;
    return _perks[playerIndex].bonusDamage;
}

- (int)debugPerkMaxHPBonusForPlayer:(int)playerIndex {
    if (playerIndex < 0 || playerIndex >= kMaxPlayers) return 0;
    return _perks[playerIndex].bonusMaxHP;
}

- (int)debugPerkLifestealForPlayer:(int)playerIndex {
    if (playerIndex < 0 || playerIndex >= kMaxPlayers) return 0;
    return _perks[playerIndex].lifestealPerHits;
}

- (BOOL)debugPerkThornsForPlayer:(int)playerIndex {
    if (playerIndex < 0 || playerIndex >= kMaxPlayers) return NO;
    return _perks[playerIndex].thorns ? YES : NO;
}

- (BOOL)debugPerkWhirlwindForPlayer:(int)playerIndex {
    if (playerIndex < 0 || playerIndex >= kMaxPlayers) return NO;
    return _perks[playerIndex].whirlwind ? YES : NO;
}

- (BOOL)debugPerkPassiveSpecialForPlayer:(int)playerIndex {
    if (playerIndex < 0 || playerIndex >= kMaxPlayers) return NO;
    return _perks[playerIndex].passiveSpecial ? YES : NO;
}

- (float)debugPerkDodgeChanceForPlayer:(int)playerIndex {
    if (playerIndex < 0 || playerIndex >= kMaxPlayers) return 0.f;
    return _perks[playerIndex].dodgeChance;
}

- (NSString *)debugPerkLabelForID:(int)perkID {
    if (perkID < 0 || perkID >= BrawlerPerkCount) return @"";
    return kPerkLabels[perkID];
}

- (void)debugApplyPerkID:(int)perkID toPlayer:(int)playerIndex {
    if (perkID < 0 || perkID >= BrawlerPerkCount) return;
    [self _applyPerk:(BrawlerPerk)perkID toPlayer:playerIndex];
}

- (void)_recordEnemyDamage:(int)amount {
    _runStats.damageDealt += amount;
    _combo += 1;
    _comboTimer = 2.5f;
    if (_combo > _runStats.maxCombo) _runStats.maxCombo = _combo;
    _runStats.score += 10 * _combo;
}

- (void)_recordPlayerDamage:(int)amount {
    _runStats.damageTaken += amount;
    _combo = 0;
    _comboTimer = 0.f;
}

- (void)_advanceComboTimerOnly:(float)dt {
    if (_combo <= 0) return;
    _comboTimer -= dt;
    if (_comboTimer <= 0.f) {
        _combo = 0;
        _comboTimer = 0.f;
    }
}

- (void)debugRegisterEnemyDamage:(int)amount { [self _recordEnemyDamage:amount]; }
- (void)debugRegisterPlayerDamage:(int)amount { [self _recordPlayerDamage:amount]; }
- (void)debugAdvanceComboTimer:(float)dt { [self _advanceComboTimerOnly:dt]; }

- (BOOL)debugShopItemsHaveDistinctPerks {
    uint8_t seen[3] = {};
    int count = 0;
    for (EntityID id = 0; id < _world.entity_count(); ++id) {
        if (!_world.shop_items().present(id)) continue;
        uint8_t perk = _world.get_component<ShopItemComponent>(id).perkID;
        for (int i = 0; i < count; ++i)
            if (seen[i] == perk) return NO;
        if (count < 3) seen[count] = perk;
        count += 1;
    }
    return count == 3;
}

- (float)debugCurseMult { return _curseMult; }
- (int)debugCurseStacks { return _curseStacks; }
- (int)debugRunCoins { return _runCoins; }
- (int)debugScrap { return _scrap; }
- (int)debugFirstPlayerMaxHP {
    for (EntityID id = 0; id < _world.entity_count(); ++id) {
        if (!_world.player_tags().present(id)) continue;
        if (!_world.has_component<HealthComponent>(id)) continue;
        return _world.get_component<HealthComponent>(id).max;
    }
    return 0;
}
- (int)debugFirstPlayerSecondWinds {
    for (EntityID id = 0; id < _world.entity_count(); ++id) {
        if (!_world.player_tags().present(id)) continue;
        if (!_world.has_component<StatsComponent>(id)) continue;
        return _world.get_component<StatsComponent>(id).secondWinds;
    }
    return 0;
}
- (int)debugFirstPlayerDodgeMaxCharges {
    for (EntityID id = 0; id < _world.entity_count(); ++id) {
        if (!_world.player_tags().present(id)) continue;
        if (!_world.has_component<DodgeChargesComponent>(id)) continue;
        return _world.get_component<DodgeChargesComponent>(id).maxCharges;
    }
    return 0;
}
- (MetaProgressStore *)debugMetaStore { return _metaStore; }
- (void)setMetaStoreOverride:(MetaProgressStore *)store {
    _metaStore = store ?: [MetaProgressStore inMemoryStore];
}
- (int)debugCursedExitType {
    for (EntityID id = 0; id < _world.entity_count(); ++id) {
        if (!_world.exits().present(id)) continue;
        const ExitComponent& exit = _world.get_component<ExitComponent>(id);
        if (exit.cursed) return exit.curseType;
    }
    return -1;
}
- (int)debugFirstEnemyMaxHP {
    for (EntityID id = 0; id < _world.entity_count(); ++id) {
        if (!_world.has_component<FactionComponent>(id)) continue;
        if (_world.get_component<FactionComponent>(id).type != FactionComponent::Enemy) continue;
        if (!_world.has_component<HealthComponent>(id)) continue;
        return _world.get_component<HealthComponent>(id).max;
    }
    return 0;
}
- (void)debugForceCurseMult:(float)mult stacks:(int)stacks {
    _curseMult = mult;
    _curseStacks = stacks;
    _world.set_curse(_curseMult);
    _renderer.curseMult = _curseMult;
}
- (void)debugApplyCurseRewardType:(int)curseType {
    [self _applyCursePortalReward:(uint8_t)curseType];
}
- (void)debugReloadCurrentRoom {
    [self _loadRoom];
}

- (void)_refreshOverlay {
    switch (_phase) {
        case BrawlerGamePhaseTitle:
            [_renderer setOverlayVisible:YES
                                   title:kBrawlerStringTitle
                                subtitle:@"Attack  PLAY     Dodge  UPGRADES"
                                 choiceA:nil choiceB:nil];
            break;
        case BrawlerGamePhasePlayerSelect:
            [_renderer setOverlayVisible:YES
                                   title:kBrawlerStringSelectPlayers
                                subtitle:nil
                                 choiceA:@"Attack  1 Player"
                                 choiceB:@"Dodge   2 Players"];
            break;
        case BrawlerGamePhasePlaying:
            [_renderer setOverlayVisible:NO title:nil subtitle:nil choiceA:nil choiceB:nil];
            break;
        case BrawlerGamePhaseRoomClear:
            [_renderer setOverlayVisible:YES
                                   title:[NSString stringWithFormat:kBrawlerStringRoomClearFmt, _currentRoom + 1]
                                subtitle:nil choiceA:nil choiceB:nil];
            break;
        case BrawlerGamePhaseWin:
            [_renderer setOverlayVisible:YES
                                   title:kBrawlerStringWin
                                subtitle:kBrawlerStringWinSubtitle choiceA:nil choiceB:nil
                               statLines:[self _runStatLines]];
            break;
        case BrawlerGamePhaseLose:
            [_renderer setOverlayVisible:YES
                                   title:kBrawlerStringGameOver
                                subtitle:nil choiceA:nil choiceB:nil
                               statLines:[self _runStatLines]];
            break;
        case BrawlerGamePhasePaused:
            [_renderer setOverlayVisible:YES
                                   title:kBrawlerStringPaused
                                subtitle:kBrawlerStringPausedResume
                                 choiceA:nil choiceB:nil];
            break;
        case BrawlerGamePhaseUpgrade:
            [_renderer setOverlayVisible:YES
                                   title:[NSString stringWithFormat:@"P%d CHOOSE UPGRADE", _upgradePlayerIndex + 1]
                                subtitle:nil
                                 choiceA:[NSString stringWithFormat:@"Attack  %@", [self upgradeChoiceLabel:0]]
                                 choiceB:[NSString stringWithFormat:@"Dodge   %@", [self upgradeChoiceLabel:1]]];
            break;
        case BrawlerGamePhaseMetaShop:
            [_renderer setOverlayVisible:YES
                                   title:@"UPGRADES"
                                subtitle:[NSString stringWithFormat:@"Coins %d", _metaStore.coins]
                                 choiceA:[self _metaShopChoiceA]
                                 choiceB:[self _metaShopChoiceB]
                               statLines:[self _metaShopLines]];
            break;
    }
}

- (NSArray<NSString*> *)_runStatLines {
    int seconds = (int)floorf(_runStats.runTime + 0.5f);
    int minutes = seconds / 60;
    seconds %= 60;
    return @[
        [NSString stringWithFormat:@"Time  %d:%02d", minutes, seconds],
        [NSString stringWithFormat:@"Enemies defeated  %d", _runStats.enemiesDefeated],
        [NSString stringWithFormat:@"Damage dealt  %d", _runStats.damageDealt],
        [NSString stringWithFormat:@"Damage taken  %d", _runStats.damageTaken],
        [NSString stringWithFormat:@"Hearts  %d", _runStats.heartsCollected],
        [NSString stringWithFormat:@"Specials  %d", _runStats.specialsUsed],
        [NSString stringWithFormat:@"Max combo  %d", _runStats.maxCombo],
        [NSString stringWithFormat:@"Score  %d", _runStats.score],
        [NSString stringWithFormat:@"Coins earned  %d", _runCoins],
    ];
}

- (NSArray<NSString*> *)_metaShopLines {
    NSMutableArray<NSString*> *lines = [NSMutableArray arrayWithCapacity:kMetaUpgradeCount];
    for (int i = 0; i < kMetaUpgradeCount; ++i)
        [lines addObject:[self metaShopLine:i]];
    return lines;
}

- (NSString *)_metaShopChoiceA {
    return @"Attack  Buy";
}

- (NSString *)_metaShopChoiceB {
    return @"Dodge/Pause  Back";
}

- (void)_refreshPerkHUD {
    for (int p = 0; p < kMaxPlayers; ++p) {
        BrawlerPerkSummary summary = {};
        for (int i = 0; i < BrawlerPerkCount && i < kBrawlerPerkTypeCount; ++i)
            summary.counts[i] = _perks[p].counts[i];
        [_renderer setPerkSummary:summary forPlayer:p];
    }
}

- (BrawlerPerk)_rollPerkByRarity {
    uint32_t roll = _world.rand_range(100);
    BrawlerPerkRarity rarity = (roll < 60) ? BrawlerRarityCommon
                               : (roll < 90) ? BrawlerRarityRare
                                             : BrawlerRarityEpic;
    uint8_t matches[BrawlerPerkCount] = {};
    int matchCount = 0;
    for (int i = 0; i < BrawlerPerkCount; ++i) {
        if (kPerkRarity[i] == rarity)
            matches[matchCount++] = (uint8_t)i;
    }
    if (matchCount <= 0) return BrawlerPerkDamage;
    return (BrawlerPerk)matches[_world.rand_range((uint32_t)matchCount)];
}

- (BrawlerPerk)_rollDistinctPerkAvoiding:(const uint8_t *)existing count:(int)existingCount {
    for (int attempt = 0; attempt < 32; ++attempt) {
        BrawlerPerk perk = [self _rollPerkByRarity];
        bool unique = true;
        for (int i = 0; i < existingCount; ++i) {
            if (existing[i] == (uint8_t)perk) {
                unique = false;
                break;
            }
        }
        if (unique) return perk;
    }
    for (int i = 0; i < BrawlerPerkCount; ++i) {
        bool unique = true;
        for (int j = 0; j < existingCount; ++j) {
            if (existing[j] == (uint8_t)i) {
                unique = false;
                break;
            }
        }
        if (unique) return (BrawlerPerk)i;
    }
    return BrawlerPerkDamage;
}

// ---------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------

- (instancetype)initWithDevice:(id<MTLDevice>)device pixelFormat:(MTLPixelFormat)pfmt {
    self = [super init];
    if (!self) return nil;

    _commandQueue   = [device newCommandQueue];
    _lastTime       = CACurrentMediaTime();
    _frameSemaphore = dispatch_semaphore_create(3);
    _renderer = [[BrawlerRenderer alloc] initWithDevice:device pixelFormat:pfmt];
    _haptics  = [[HapticsEngine alloc] init];
    [_haptics startupInit];
    _audio    = [[AudioEngine alloc] init];
    [_audio startupInit];
    _metaStore = [MetaProgressStore defaultsStore];

    [self _loadCharacters:device];
    _numPlayers = 1; // default; overridden at player-select
    _phase = BrawlerGamePhaseTitle;
    [self _refreshOverlay];

    return self;
}

- (instancetype)initHeadless {
    self = [super init];
    if (!self) return nil;

    // No command queue, renderer, audio, haptics, or meshes — every message to
    // those nil ivars is a no-op, so the full game logic runs unchanged.
    _lastTime   = CACurrentMediaTime();
    _numPlayers = 1;
    _phase      = BrawlerGamePhaseTitle;
    _metaStore  = [MetaProgressStore inMemoryStore];

    return self;
}

- (LoadedCharacter *)_loadCharacterIn:(NSString *)folder
                                 mesh:(NSString *)meshName
                               device:(id<MTLDevice>)device {
    NSString *res = [NSBundle mainBundle].resourcePath;
    NSString *dir = [res stringByAppendingPathComponent:
                     [@"assets/characters" stringByAppendingPathComponent:folder]];
    NSString *mesh = [dir stringByAppendingPathComponent:meshName];
    if (![[NSFileManager defaultManager] fileExistsAtPath:mesh]) return nullptr;

    // Order must match AnimClipID: Idle, Walk, Attack, Hurt, Death, Dodge, Attack2, Run.
    NSMutableArray<NSString*> *clips = [NSMutableArray array];
    for (NSString *n in @[@"idle.usdz", @"walk.usdz", @"attack.usdz",
                           @"hurt.usdz", @"death.usdz", @"dodge.usdz",
                           @"attack2.usdz", @"run.usdz"])
        [clips addObject:[dir stringByAppendingPathComponent:n]];

    return CharacterLoader_load(mesh, clips, device);
}

- (void)_loadCharacters:(id<MTLDevice>)device {
    LoadedCharacter *player = [self _loadCharacterIn:@"player"
                                                mesh:@"Ch24_nonPBR.usdz" device:device];
    LoadedCharacter *enemy  = [self _loadCharacterIn:@"enemy"
                                                mesh:@"PumpkinhulkLShaw.usdz" device:device];
    if (!enemy) enemy = player; // enemy assets absent — fall back to tinted player

    AnimationSystem_set_characters(player, enemy);
    [_renderer setPlayerCharacter:player enemyCharacter:enemy];
}

// ---------------------------------------------------------------------------
// Game state helpers
// ---------------------------------------------------------------------------

- (void)_transitionToPhase:(BrawlerGamePhase)newPhase {
    if (_phase == newPhase) return;
    _phase = newPhase;
    switch (newPhase) {
        case BrawlerGamePhaseTitle:
            [_audio stopMusic];
            break;
        case BrawlerGamePhasePlayerSelect:
            [self resetInput]; // clear any button that triggered the title→select transition
            [_audio playUIClickSound];
            break;
        case BrawlerGamePhaseMetaShop:
            [self resetInput];
            _phaseTimer = kUpgradeGrace;
            [_audio playUIClickSound];
            break;
        case BrawlerGamePhasePlaying:
            [_audio resumeMusic];
            [_audio startBattleMusic];
            _phaseTimer = 0;
            break;
        case BrawlerGamePhaseRoomClear:
            _phaseTimer = kRoomClearDuration;
            [_audio playRoomClearSound];
            break;
        case BrawlerGamePhaseWin:
            [_audio stopMusic];
            _phaseTimer = kWinDuration;
            _runCoins += 25;
            [self _bankRunCoinsIfNeeded];
            break;
        case BrawlerGamePhaseLose:
            [_audio stopMusic];
            _phaseTimer = kLoseDuration;
            [self _bankRunCoinsIfNeeded];
            break;
        case BrawlerGamePhasePaused:
            [_audio pauseMusic];
            break;
        case BrawlerGamePhaseUpgrade:
            [self resetInput];
            _phaseTimer = kUpgradeGrace; // brief grace so held buttons don't insta-pick
            break;
    }
    if (self.onPhaseChanged)
        self.onPhaseChanged(newPhase, _currentRoom + 1, _lives);
    [self _refreshOverlay];
}

- (void)_startNewRun {
    AutoPilot_reset();
    _currentRoom = 0;
    _lives       = kStartingLives + _metaStore.livesLevel;
    for (int i = 0; i < kMaxPlayers; ++i)
        _perks[i] = PlayerPerks{};
    for (int i = 0; i < kMaxPlayers; ++i) {
        _perks[i].bonusMaxHP += _metaStore.hpLevel;
        _perks[i].secondWinds += _metaStore.secondWindLevel;
    }
    _runStats = RunStats{};
    _scrap = _metaStore.scrapLevel * 15;
    _curseMult = 1.f;
    _curseStacks = 0;
    _runCoins = 0;
    _runCoinsBanked = NO;
    _combo = 0;
    _comboTimer = 0.f;
    [self _refreshPerkHUD];
    _upgradePlayerIndex = -1;

    // Seeded Fisher-Yates over the middle-room pool: rooms 2..N-1 differ per
    // run (the run plays kMiddlePerRun of kNumMiddleRooms), deterministic when
    // rngSeedOverride is set.
    uint32_t s = self.rngSeedOverride ? self.rngSeedOverride : arc4random();
    if (!s) s = 1;
    for (int i = 0; i < kNumMiddleRooms; ++i) _middleOrder[i] = i;
    for (int i = kNumMiddleRooms - 1; i > 0; --i) {
        s ^= s << 13; s ^= s >> 17; s ^= s << 5;
        int j = (int)(s % (uint32_t)(i + 1));
        int t = _middleOrder[i]; _middleOrder[i] = _middleOrder[j]; _middleOrder[j] = t;
    }

    _phase = (BrawlerGamePhase)-1; // sentinel: force the first transition to fire
    [self _loadRoom];
    [self _transitionToPhase:BrawlerGamePhasePlaying];
}

- (void)_bankRunCoinsIfNeeded {
    if (_runCoinsBanked) return;
    _runCoinsBanked = YES;
    if (_runCoins <= 0) return;
    _metaStore.coins += _runCoins;
    [_metaStore save];
}

- (void)enterMetaShop {
    if (_phase != BrawlerGamePhaseTitle) return;
    _metaShopIndex = 0;
    [self _transitionToPhase:BrawlerGamePhaseMetaShop];
}

- (void)exitMetaShop {
    if (_phase != BrawlerGamePhaseMetaShop) return;
    [self _transitionToPhase:BrawlerGamePhaseTitle];
}

- (void)metaShopMove:(int)delta {
    if (_phase != BrawlerGamePhaseMetaShop || delta == 0) return;
    _metaShopIndex += delta;
    if (_metaShopIndex < 0) _metaShopIndex = kMetaUpgradeCount - 1;
    if (_metaShopIndex >= kMetaUpgradeCount) _metaShopIndex = 0;
    [self _refreshOverlay];
}

- (int)currentMetaShopIndex { return _metaShopIndex; }

- (NSString *)metaShopLine:(int)index {
    if (index < 0 || index >= kMetaUpgradeCount) return @"";
    BrawlerMetaUpgrade upgrade = (BrawlerMetaUpgrade)index;
    int level = meta_level_for_upgrade(_metaStore, upgrade);
    int maxLevel = meta_max_level(upgrade);
    NSString *prefix = (index == _metaShopIndex) ? @"> " : @"  ";
    if (level >= maxLevel)
        return [NSString stringWithFormat:@"%@%@ %d/%d %@ MAX", prefix, meta_name(upgrade), level, maxLevel, meta_effect(upgrade)];
    return [NSString stringWithFormat:@"%@%@ %d/%d %@ cost %d", prefix, meta_name(upgrade), level, maxLevel, meta_effect(upgrade), meta_cost(upgrade, level)];
}

- (BOOL)buySelectedMetaUpgrade {
    if (_phase != BrawlerGamePhaseMetaShop) return NO;
    BrawlerMetaUpgrade upgrade = (BrawlerMetaUpgrade)_metaShopIndex;
    int level = meta_level_for_upgrade(_metaStore, upgrade);
    int maxLevel = meta_max_level(upgrade);
    if (level >= maxLevel) return NO;
    int cost = meta_cost(upgrade, level);
    if (_metaStore.coins < cost) return NO;
    _metaStore.coins -= cost;
    switch (upgrade) {
        case BrawlerMetaUpgradeVitality:   _metaStore.hpLevel += 1; break;
        case BrawlerMetaUpgradeExtraLife:  _metaStore.livesLevel += 1; break;
        case BrawlerMetaUpgradeProspector: _metaStore.scrapLevel += 1; break;
        case BrawlerMetaUpgradeResolve:    _metaStore.secondWindLevel += 1; break;
    }
    [_metaStore save];
    [_audio playUIClickSound];
    [self _refreshOverlay];
    return YES;
}

- (const RoomDef&)_currentRoomDef {
    if (_currentRoom <= 0)              return kIntroRoom;
    if (_currentRoom == kShopRoomIndex) return kShopRoom;
    if (_currentRoom == kNumRooms - 1)  return kFinalRoom;
    if (_currentRoom == kNumRooms - 2)  return kBossRoom;
    int middleSlot = (_currentRoom < kShopRoomIndex) ? (_currentRoom - 1)
                                                     : (_currentRoom - 2);
    return kMiddleRooms[_middleOrder[middleSlot]];
}

// Roll two distinct perks from the pool using the (seeded) world RNG so
// deterministic runs offer deterministic choices.
- (void)_rollUpgradeChoices {
    uint8_t picks[2] = {};
    picks[0] = (uint8_t)[self _rollDistinctPerkAvoiding:picks count:0];
    picks[1] = (uint8_t)[self _rollDistinctPerkAvoiding:picks count:1];
    _upgradeChoice[0] = picks[0];
    _upgradeChoice[1] = picks[1];
}

- (NSString *)upgradeChoiceLabel:(int)index {
    if (index < 0 || index > 1) return @"";
    BrawlerPerk perk = (BrawlerPerk)_upgradeChoice[index];
    return [NSString stringWithFormat:@"%@%@", rarity_prefix(perk), kPerkLabels[perk]];
}

- (void)_applyPerk:(BrawlerPerk)chosen toPlayer:(int)playerIndex {
    if (playerIndex < 0 || playerIndex >= kMaxPlayers) return;
    PlayerPerks& perks = _perks[playerIndex];
    switch (chosen) {
        case BrawlerPerkDamage: perks.bonusDamage += 1;    break;
        case BrawlerPerkSpeed:  perks.speedMult   += 0.1f; break;
        case BrawlerPerkMaxHP:  perks.bonusMaxHP  += 3;    break;
        case BrawlerPerkLife:   _lives += 1;               break;
        case BrawlerPerkKnockback:     perks.knockbackMult *= 1.2f; break;
        case BrawlerPerkQuickDodge:    perks.dodgeCooldownMult *= 0.7f; break;
        case BrawlerPerkSpecialCharge: perks.specialChargeMult += 0.25f; break;
        case BrawlerPerkSecondWind:    perks.secondWinds += 1; break;
        case BrawlerPerkHeavyHitter:   perks.bonusDamage += 1; break;
        case BrawlerPerkToughness:     perks.bonusMaxHP += 4; break;
        case BrawlerPerkLifesteal:     perks.lifestealPerHits = 10; break;
        case BrawlerPerkThorns:        perks.thorns = true; break;
        case BrawlerPerkWhirlwind:     perks.whirlwind = true; break;
        case BrawlerPerkAdrenaline:    perks.passiveSpecial = true; break;
        case BrawlerPerkVampire:
            perks.lifestealPerHits = 6;
            break;
        case BrawlerPerkEvasion:       perks.bonusDodgeCharges += 1; break;
        case BrawlerPerkDodgeChance:   perks.dodgeChance += 0.05f; break;
        case BrawlerPerkCount:  break;
    }
    if (chosen >= 0 && chosen < BrawlerPerkCount) {
        perks.counts[chosen] += 1;
        _runStats.perksTaken += 1;
    }
}

- (void)chooseUpgrade:(int)index {
    if (_phase != BrawlerGamePhaseUpgrade) return;
    if (index < 0 || index > 1) return;
    if (_upgradePlayerIndex < 0 || _upgradePlayerIndex >= _numPlayers) return;

    BrawlerPerk chosen = (BrawlerPerk)_upgradeChoice[index];
    [self _applyPerk:chosen toPlayer:_upgradePlayerIndex];
    [self _refreshPerkHUD];
    [_audio playUIClickSound];

    // Multiplayer: each active player gets their own fresh, deterministic
    // upgrade offer before the next room starts.
    if (_upgradePlayerIndex + 1 < _numPlayers) {
        _upgradePlayerIndex += 1;
        [self _rollUpgradeChoices];
        [self resetInput];
        _phaseTimer = kUpgradeGrace;
        if (self.onPhaseChanged)
            self.onPhaseChanged(BrawlerGamePhaseUpgrade, _currentRoom + 1, _lives);
        [self _refreshOverlay];
        return;
    }

    _upgradePlayerIndex = -1;
    [self _spawnExitsForNextRoom];
    [self _transitionToPhase:BrawlerGamePhasePlaying];
}

- (void)_loadRoom {
    _world = World();
    _world.set_seed(self.rngSeedOverride ? self.rngSeedOverride : arc4random());
    _world.set_scrap(_scrap);
    _world.set_difficulty(_currentRoom);
    _world.set_curse(_curseMult);
    [self resetInput];
    [self _spawnPlayers];
    [self _spawnWaveControllerForCurrentRoom];
    [self _spawnObstaclesForCurrentRoom];
    [self _spawnBoxesForCurrentRoom];
    if ([self _currentRoomDef].isShop) {
        [self _spawnExitsForNextRoom];
        [self _spawnShopkeeper];
        [self _spawnShopItems];
    }
    _renderer.livesRemaining = _lives;
    _renderer.totalRooms = kNumRooms;
    _renderer.scrapCount = _scrap;
    _renderer.curseMult = _curseMult;
    [self _refreshPerkHUD];
    _renderer.roomIndex = _currentRoom;
}

- (void)_spawnExit {
    EntityID exit = _world.defer_create();
    _world.add_component<PositionComponent>(exit) = {0.f, kRoomMaxY - 60.f, 0.f};
    _world.add_component<ExitComponent>(exit);
}

- (void)_spawnExitAtX:(float)x cursed:(BOOL)cursed curseType:(uint8_t)curseType {
    EntityID exit = _world.defer_create();
    _world.add_component<PositionComponent>(exit) = {x, kRoomMaxY - 60.f, 0.f};
    ExitComponent& ex = _world.add_component<ExitComponent>(exit);
    ex.cursed = cursed ? true : false;
    ex.curseType = curseType;
}

- (void)_spawnExitsForNextRoom {
    if (_currentRoom + 1 >= kNumRooms) return;
    int nextRoom = _currentRoom + 1;
    // Curse choice offered whenever the next room is not the shop (shops can't be
    // cursed). Leaving the shop into a combat room DOES offer the choice.
    bool nextIsShop = (nextRoom == kShopRoomIndex);
    if (nextIsShop) {
        [self _spawnExitAtX:0.f cursed:NO curseType:0];
        return;
    }
    [self _spawnExitAtX:-220.f cursed:NO curseType:0];
    [self _spawnExitAtX:220.f cursed:YES curseType:(uint8_t)_world.rand_range(kCurseTypeCount)];
}

- (void)_healActivePlayersBy:(int)amount {
    for (EntityID id = 0; id < _world.entity_count(); ++id) {
        if (!_world.player_tags().present(id)) continue;
        if (!_world.has_component<HealthComponent>(id)) continue;
        HealthComponent& hp = _world.get_component<HealthComponent>(id);
        hp.current += amount;
        if (hp.current > hp.max) hp.current = hp.max;
    }
}

- (void)_applyCursePortalReward:(uint8_t)curseType {
    int coins = curse_coin_reward(curseType, _curseStacks);
    _runCoins += coins;
    if (curseType == 1) {
        _scrap += 40;
        _world.set_scrap(_scrap);
        _renderer.scrapCount = _scrap;
    } else if (curseType == 2) {
        [self _healActivePlayersBy:3];
    }
    _curseMult *= curse_factor(curseType);
    _curseStacks += 1;
    _world.set_curse(_curseMult);
    _renderer.curseMult = _curseMult;
    [_renderer triggerHitBlur:1.f];
    ScreenShakeSystem_trigger(_world, 28.f);
    [_audio playFinisherSound];
}

- (void)_spawnPlayers {
    static const float kSpawnX[kMaxPlayers] = { -180.f, 180.f, -60.f, 60.f };
    static const float kSpawnY[kMaxPlayers] = { -120.f, -120.f, -220.f, -220.f };
    if (_numPlayers == 1) {
        [self _spawnPlayer:0 at:0 y:-120];
        return;
    }
    for (int i = 0; i < _numPlayers && i < kMaxPlayers; ++i)
        [self _spawnPlayer:(uint8_t)i at:kSpawnX[i] y:kSpawnY[i]];
}

- (void)_spawnPlayer:(uint8_t)index at:(float)x y:(float)y {
    EntityID e = _world.defer_create();
    _world.add_component<PlayerTagComponent>(e) = {true, index};
    _world.add_component<PositionComponent>(e)  = {x, y, 0};
    _world.add_component<VelocityComponent>(e)  = {0, 0, 0};
    _world.add_component<FactionComponent>(e).type = FactionComponent::Player;
    const PlayerPerks& perks = _perks[index];
    int maxHP = 10 + perks.bonusMaxHP;
    _world.add_component<HealthComponent>(e)    = {maxHP, maxHP};
    _world.add_component<DamageCooldownComponent>(e).remaining = 0.f;
    _world.add_component<AnimationComponent>(e);
    _world.add_component<FacingComponent>(e);
    _world.add_component<SpecialMeterComponent>(e);
    _world.add_component<ChargeAttackComponent>(e);
    DodgeChargesComponent& dodgeCharges = _world.add_component<DodgeChargesComponent>(e);
    dodgeCharges.maxCharges = 2 + perks.bonusDodgeCharges;
    dodgeCharges.charges = dodgeCharges.maxCharges;
    dodgeCharges.regenTimer = 0.f;
    auto& stats = _world.add_component<StatsComponent>(e);
    stats.damageBonus = perks.bonusDamage;
    stats.speedMult   = perks.speedMult;
    stats.knockbackMult = perks.knockbackMult;
    stats.dodgeCooldownMult = perks.dodgeCooldownMult;
    stats.dodgeChance = fminf(perks.dodgeChance, 0.3f);
    stats.specialChargeMult = perks.specialChargeMult;
    stats.secondWinds = perks.secondWinds;
    stats.lifestealPerHits = perks.lifestealPerHits;
    stats.thorns = perks.thorns;
    stats.whirlwind = perks.whirlwind;
    stats.passiveSpecial = perks.passiveSpecial;
}

- (void)_spawnWaveControllerForCurrentRoom {
    const RoomDef& room = [self _currentRoomDef];
    if (room.isShop) return;
    EntityID controller = _world.defer_create();
    WaveControllerComponent& wave = _world.add_component<WaveControllerComponent>(controller);
    wave.spawnCount = room.count;
    wave.waveCount = 0;
    wave.currentWave = 0;
    wave.timer = kInitialWaveDelay;
    wave.phase = WavePhaseInitialDelay;
    wave.bossMode = (_currentRoom >= kNumRooms - 2);
    wave.bossMinionCap = (_currentRoom == kNumRooms - 1) ? kFinalBossMinionCap : kBossMinionCap;
    for (int i = 0; i < room.count; ++i) {
        const EnemySpawn& spawn = room.spawns[i];
        wave.spawns[i] = {(uint8_t)spawn.type, spawn.wave, spawn.x, spawn.y};
        if ((int)spawn.wave + 1 > wave.waveCount)
            wave.waveCount = (int)spawn.wave + 1;
    }
    if (wave.bossMode) {
        wave.reinforceCount = (int)(sizeof(kBossReinforcements) / sizeof(kBossReinforcements[0]));
        for (int i = 0; i < wave.reinforceCount; ++i) {
            const EnemySpawn& spawn = kBossReinforcements[i];
            wave.reinforcements[i] = {(uint8_t)spawn.type, spawn.wave, spawn.x, spawn.y};
        }
    }
}

- (void)_spawnObstaclesForCurrentRoom {
    const RoomDef& room = [self _currentRoomDef];
    for (int i = 0; i < room.obstacleCount; ++i) {
        const ObstacleSpawn& spawn = room.obstacles[i];
        EntityID e = _world.defer_create();
        _world.add_component<PositionComponent>(e) = {spawn.x, spawn.y, 0.f};
        _world.add_component<ObstacleComponent>(e) = {spawn.halfW, spawn.halfH};
    }
}

- (void)_spawnBoxesForCurrentRoom {
    const RoomDef& room = [self _currentRoomDef];
    for (int i = 0; i < room.boxCount; ++i) {
        const BoxSpawn& spawn = room.boxes[i];
        EntityID e = _world.defer_create();
        _world.add_component<PositionComponent>(e) = {spawn.x, spawn.y, 0.f};
        _world.add_component<BoxComponent>(e).hasScrap = spawn.hasScrap;
    }
}

- (void)_spawnShopkeeper {
    EntityID e = _world.defer_create();
    _world.add_component<PositionComponent>(e) = {0.f, 380.f, 0.f};
    _world.add_component<VelocityComponent>(e) = {0.f, 0.f, 0.f};
    _world.add_component<AnimationComponent>(e);
    _world.add_component<FacingComponent>(e);
    _world.add_component<ShopkeeperComponent>(e);
}

- (void)_spawnShopItems {
    uint8_t picks[3] = {};
    for (int i = 0; i < 3; ++i) {
        picks[i] = (uint8_t)[self _rollDistinctPerkAvoiding:picks count:i];
    }
    static const float kShopX[3] = {-250.f, 0.f, 250.f};
    for (int i = 0; i < 3; ++i) {
        EntityID e = _world.defer_create();
        _world.add_component<PositionComponent>(e) = {kShopX[i], 150.f, 0.f};
        ShopItemComponent& item = _world.add_component<ShopItemComponent>(e);
        item.perkID = picks[i];
        item.price = rarity_price((BrawlerPerk)picks[i]);
    }
}

- (void)_applyShopPerk:(BrawlerPerk)perk {
    for (int p = 0; p < _numPlayers && p < kMaxPlayers; ++p)
        [self _applyPerk:perk toPlayer:p];
    [self _refreshPerkHUD];
}

- (void)_refreshShopPrompt {
    if (![self _currentRoomDef].isShop) {
        _renderer.shopPrompt = @"";
        return;
    }
    EntityID nearestItem = kInvalidEntity;
    float nearestD2 = 0.f;
    for (EntityID itemID = 0; itemID < _world.entity_count(); ++itemID) {
        if (!_world.shop_items().present(itemID)) continue;
        if (!_world.has_component<PositionComponent>(itemID)) continue;
        const PositionComponent& ipos = _world.get_component<PositionComponent>(itemID);
        for (EntityID playerID = 0; playerID < _world.entity_count(); ++playerID) {
            if (!_world.player_tags().present(playerID)) continue;
            if (!_world.has_component<PositionComponent>(playerID)) continue;
            if (!_world.has_component<HealthComponent>(playerID)) continue;
            if (_world.has_component<DownedComponent>(playerID)) continue;
            const PositionComponent& ppos = _world.get_component<PositionComponent>(playerID);
            float dx = ppos.x - ipos.x;
            float dy = ppos.y - ipos.y;
            float d2 = dx * dx + dy * dy;
            if (d2 > 110.f * 110.f) continue;
            if (nearestItem == kInvalidEntity || d2 < nearestD2) {
                nearestItem = itemID;
                nearestD2 = d2;
            }
        }
    }
    if (nearestItem == kInvalidEntity) {
        _renderer.shopPrompt = @"";
        return;
    }
    const ShopItemComponent& item = _world.get_component<ShopItemComponent>(nearestItem);
    NSString *label = (item.perkID < BrawlerPerkCount) ? kPerkLabels[item.perkID] : @"Perk";
    NSString *prefix = (item.perkID < BrawlerPerkCount) ? rarity_prefix((BrawlerPerk)item.perkID) : @"";
    _renderer.shopPrompt = [NSString stringWithFormat:@"%@%@ - %d SCRAP (PUNCH TO BUY)",
                            prefix, label, item.price];
}

// Returns YES when no enemy entities remain in the world — i.e. all death
// animations have finished and AnimationSystem has removed the entities.
// Checking the dying flag would trigger too early (entities still visible
// mid-animation); waiting for removal means the room-clear message only
// appears after the last enemy has fully collapsed.
- (BOOL)_allEnemiesDefeated {
    if ([self _currentRoomDef].isShop)
        return NO;
    if ([self exitEntityCount] > 0)
        return NO;
    if (!WaveSystem_room_finished(_world))
        return NO;
    for (EntityID id = 0; id < _world.entity_count(); ++id) {
        if (!_world.has_component<FactionComponent>(id)) continue;
        if (_world.get_component<FactionComponent>(id).type == FactionComponent::Enemy)
            return NO; // at least one enemy (alive or mid-death-anim) still exists
    }
    return YES;
}

// Returns YES when every player is either downed or in their death animation.
- (BOOL)_allPlayersDying {
    int playerCount = 0, defeatedCount = 0;
    for (EntityID id = 0; id < _world.entity_count(); ++id) {
        if (!_world.player_tags().present(id)) continue;
        playerCount++;
        if (_world.has_component<DownedComponent>(id) ||
            (_world.has_component<AnimationComponent>(id) &&
             _world.get_component<AnimationComponent>(id).dying))
            defeatedCount++;
    }
    return playerCount > 0 && defeatedCount == playerCount;
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

- (void)setInputState:(InputState)state forPlayer:(int)p { _world.set_input(state, p); }
- (InputState)currentInputStateForPlayer:(int)p          { return _world.current_input(p); }
- (void)setInputState:(InputState)state                  { _world.set_input(state, 0); }
- (InputState)currentInputState                          { return _world.current_input(0); }
- (void)startGameWithPlayers:(int)playerCount {
    _numPlayers = MAX(1, MIN(kMaxPlayers, playerCount));
    [self _startNewRun];
}

- (void)captureNextFrameToPath:(NSString *)path          { [_renderer captureNextFrameToPath:path]; }

- (void)triggerAttack                                    { _attackPulse = YES; }
- (void)triggerDodge                                     { _dodgePulse  = YES; }
- (void)triggerSpecial                                   { _specialPulse = YES; }
- (void)triggerPause                                     { _pausePulse  = YES; }

- (void)resetInput {
    InputState zero = {};
    for (int i = 0; i < 4; ++i) _world.set_input(zero, i);
    _attackPulse = NO;
    _dodgePulse  = NO;
    _pausePulse  = NO;
    _specialPulse = NO;
}

// ---------------------------------------------------------------------------
// MTKViewDelegate
// ---------------------------------------------------------------------------

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    [_renderer updateDrawableSize:size];
}

// One frame of game logic, independent of rendering: input pulses, simulation,
// event→audio/haptics routing, phase state machine. Headless drivers (scenario
// tests, --autotest) call this directly with a fixed dt.
- (void)advanceFrame:(float)dt {
    if (_phase == BrawlerGamePhasePlaying)
        _runStats.runTime += dt;
    if (_phase == BrawlerGamePhasePlaying)
        [self _advanceComboTimerOnly:dt];

    // AutoPilot (scenario tests, --autotest): bot input replaces human input.
    if (self.autoPilotEnabled && _phase == BrawlerGamePhasePlaying) {
        for (int p = 0; p < _numPlayers; ++p)
            _world.set_input(AutoPilot_input(_world, p), p);
    }

    // Single-frame pulses (touch tap / flick / pause).
    if (_attackPulse || _dodgePulse || _specialPulse) {
        InputState s = _world.current_input(0);
        if (_attackPulse) s.attack = true;
        if (_dodgePulse)  s.dodge  = true;
        if (_specialPulse) s.special = true;
        _world.set_input(s, 0);
    }

    // Title, Paused, and Upgrade phases freeze the simulation.
    BOOL simActive = (_phase != BrawlerGamePhaseTitle &&
                      _phase != BrawlerGamePhasePaused &&
                      _phase != BrawlerGamePhaseUpgrade &&
                      _phase != BrawlerGamePhaseMetaShop);

    if (simActive) {
        _world.set_scrap(_scrap);
        _world.update(dt, dt);
        _renderer.scrapCount = _scrap;
        _renderer.comboCount = _combo;
        _renderer.scoreValue = _runStats.score;
        [self _refreshShopPrompt];

        // Play hit sound/haptic once per frame regardless of how many enemies connected —
        // queuing one buffer per HitContact event causes sounds to pile up sequentially.
        // The finisher (Attack2) gets its own heavier sound + haptic.
        bool hitThisFrame = false;
        _world.events().for_each(EventType::HitContact, [self, &hitThisFrame](const Event& ev) {
            uint32_t atk = ev.hitContact.attackerID;
            uint32_t tgt = ev.hitContact.targetID;
            bool finisher = _world.has_component<AnimationComponent>(atk) &&
                            _world.get_component<AnimationComponent>(atk).currentClip
                                == AnimClipID::Attack2;

            // Spark burst at the impact point — per contact, not per frame.
            // Kept light and cartoony (kid-friendly): a few gold sparks, no gore.
            if (_world.has_component<PositionComponent>(tgt)) {
                const auto& p = _world.get_component<PositionComponent>(tgt);
                if (finisher)
                    [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 90.f}
                                      count:12 speed:420.f size:14.f
                                      color:(simd_float4){1.0f, 0.45f, 0.15f, 1.f}];
                else
                    [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 80.f}
                                      count:6 speed:300.f size:10.f
                                      color:(simd_float4){1.0f, 0.85f, 0.35f, 1.f}];
            }

            if (hitThisFrame) return; // sound/haptic/blur once per frame
            hitThisFrame = true;
            [_renderer triggerHitBlur:finisher ? 1.f : 0.45f];
            // No impact thud on regular hits — the swing whoosh (AttackStarted)
            // carries the punch; only the finisher gets an audible accent.
            if (finisher) {
                [_audio  playFinisherSound];
                [_haptics playFinisherHaptic];
            } else {
                [_haptics playHitHaptic];
            }
        });

        // Swing whoosh + light haptic when a player's punch starts (whiff or not).
        // Player-only: four grunts swinging at once would be a wall of noise.
        bool swingThisFrame = false;
        _world.events().for_each(EventType::AttackStarted, [self, &swingThisFrame](const Event& ev) {
            if (swingThisFrame) return;
            if (!_world.player_tags().present(ev.attackStarted.entityID)) return;
            swingThisFrame = true;
            [_audio  playSwingSound];
            [_haptics playAttackHaptic];
        });

        _world.events().for_each(EventType::DodgeStarted, [self](const Event& ev) {
            if (!_world.player_tags().present(ev.dodgeStarted.entityID)) return;
            [_audio  playDodgeSound];
            [_haptics playDodgeHaptic];
        });

        _world.events().for_each(EventType::SpecialUsed, [self](const Event& ev) {
            _runStats.specialsUsed += 1;
            uint32_t pid = ev.specialUsed.entityID;
            if (_world.has_component<PositionComponent>(pid)) {
                const auto& p = _world.get_component<PositionComponent>(pid);
                [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 110.f}
                                  count:36 speed:520.f size:16.f
                                  color:(simd_float4){1.0f, 0.8f, 0.2f, 1.f}];
            }
            [_renderer triggerHitBlur:1.f];
            [_audio playFinisherSound];
            [_haptics playFinisherHaptic];
        });

        _world.events().for_each(EventType::ChargeReady, [self](const Event& ev) {
            uint32_t pid = ev.chargeReady.playerID;
            if (_world.has_component<PositionComponent>(pid)) {
                const auto& p = _world.get_component<PositionComponent>(pid);
                [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 105.f}
                                  count:18 speed:180.f size:14.f
                                  color:(simd_float4){0.35f, 0.70f, 1.0f, 1.f}];
            }
            [_audio playSwingSound];
        });

        _world.events().for_each(EventType::ChargedSlam, [self](const Event& ev) {
            [_renderer spawnBurstAt:(simd_float3){ev.chargedSlam.x, ev.chargedSlam.y, 95.f}
                              count:44 speed:560.f size:18.f
                              color:(simd_float4){1.0f, 0.82f, 0.25f, 1.f}];
            [_renderer triggerHitBlur:1.f];
            [_audio playFinisherSound];
            [_haptics playFinisherHaptic];
        });

        // Ember trail on every lava snake (a few particles per frame).
        for (EntityID id = 0; id < _world.entity_count(); ++id) {
            if (!_world.hazards().present(id)) continue;
            if (!_world.has_component<PositionComponent>(id)) continue;
            const auto& p = _world.get_component<PositionComponent>(id);
            [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 14.f}
                              count:1 speed:90.f size:9.f
                              color:(simd_float4){1.0f, 0.5f, 0.12f, 1.f}];
        }

        for (EntityID id = 0; id < _world.entity_count(); ++id) {
            if (!_world.projectiles().present(id)) continue;
            if (!_world.has_component<PositionComponent>(id)) continue;
            const auto& p = _world.get_component<PositionComponent>(id);
            [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 18.f}
                              count:1 speed:70.f size:7.f
                              color:(simd_float4){1.0f, 0.6f, 0.2f, 1.f}];
        }

        // Spawn markers glow on the floor before enemies arrive.
        for (EntityID id = 0; id < _world.entity_count(); ++id) {
            if (!_world.spawn_markers().present(id)) continue;
            if (!_world.has_component<PositionComponent>(id)) continue;
            const auto& p = _world.get_component<PositionComponent>(id);
            [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 18.f}
                              count:1 speed:80.f size:8.f
                              color:(simd_float4){1.0f, 0.58f, 0.16f, 1.f}];
        }

        _world.events().for_each(EventType::SpawnLanded, [self](const Event& ev) {
            uint32_t eid = ev.spawnLanded.entityID;
            if (_world.has_component<PositionComponent>(eid)) {
                const auto& p = _world.get_component<PositionComponent>(eid);
                [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 30.f}
                                  count:14 speed:230.f size:13.f
                                  color:(simd_float4){0.72f, 0.68f, 0.62f, 1.f}];
            }
            if (ev.spawnLanded.style == SpawnStyleSkyDrop)
                [_audio playDodgeSound];
        });

        _world.events().for_each(EventType::LavaPoolSpawned, [self](const Event& ev) {
            [_renderer spawnBurstAt:(simd_float3){ev.lavaPoolSpawned.x, ev.lavaPoolSpawned.y, 35.f}
                              count:24 speed:330.f size:16.f
                              color:(simd_float4){1.0f, 0.48f, 0.10f, 1.f}];
            [_audio playFinisherSound];
        });

        // Boss winding up a charge: warning burst + an audible cue.
        _world.events().for_each(EventType::BossTelegraph, [self](const Event& ev) {
            uint32_t bid = ev.bossTelegraph.entityID;
            if (_world.has_component<PositionComponent>(bid)) {
                const auto& p = _world.get_component<PositionComponent>(bid);
                [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 120.f}
                                  count:32 speed:260.f size:18.f
                                  color:(simd_float4){1.0f, 0.15f, 0.10f, 1.f}];
            }
            [_audio playSwingSound];
        });

        _world.events().for_each(EventType::BossEnraged, [self](const Event& ev) {
            uint32_t bid = ev.bossEnraged.entityID;
            if (_world.has_component<PositionComponent>(bid)) {
                const auto& p = _world.get_component<PositionComponent>(bid);
                [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 130.f}
                                  count:40 speed:520.f size:20.f
                                  color:(simd_float4){1.0f, 0.05f, 0.03f, 1.f}];
            }
            [_renderer triggerHitBlur:1.f];
            [_audio playFinisherSound];
        });

        _world.events().for_each(EventType::EntityDied, [self](const Event& ev) {
            uint32_t died = ev.entityDied.entityID;
            if (_world.player_tags().present(died)) {
                [_audio playHurtSound];
            } else {
                _runStats.enemiesDefeated += 1;
                [_audio  playDeathSound];
                [_haptics playDeathHaptic];
                // Soft golden "poof" — deliberately not red (kid-friendly).
                if (_world.has_component<PositionComponent>(died)) {
                    const auto& p = _world.get_component<PositionComponent>(died);
                    [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 60.f}
                                      count:10 speed:280.f size:12.f
                                      color:(simd_float4){1.0f, 0.85f, 0.50f, 1.f}];
                }
            }
        });

        _world.events().for_each(EventType::PickupCollected, [self](const Event& ev) {
            _runStats.heartsCollected += 1;
            uint32_t pid = ev.pickupCollected.playerID;
            if (_world.has_component<PositionComponent>(pid)) {
                const auto& p = _world.get_component<PositionComponent>(pid);
                [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 70.f}
                                  count:10 speed:200.f size:10.f
                                  color:(simd_float4){1.0f, 0.5f, 0.6f, 1.f}];
            }
            [_audio playRoomClearSound];
        });

        _world.events().for_each(EventType::ScrapCollected, [self](const Event& ev) {
            _scrap += ev.scrapCollected.value;
            _world.set_scrap(_scrap);
            _renderer.scrapCount = _scrap;
            [_audio playRoomClearSound];
        });

        _world.events().for_each(EventType::BoxBroken, [self](const Event& ev) {
            [_renderer spawnBurstAt:(simd_float3){ev.boxBroken.x, ev.boxBroken.y, 35.f}
                              count:12 speed:220.f size:13.f
                              color:(simd_float4){0.55f, 0.38f, 0.20f, 1.f}];
            [_audio playSwingSound];
        });

        _world.events().for_each(EventType::ShopPurchase, [self](const Event& ev) {
            _scrap -= ev.shopPurchase.price;
            if (_scrap < 0) _scrap = 0;
            _world.set_scrap(_scrap);
            _renderer.scrapCount = _scrap;
            [self _applyShopPerk:(BrawlerPerk)ev.shopPurchase.perkID];
            if (_world.has_component<PositionComponent>(ev.shopPurchase.itemEID)) {
                const auto& p = _world.get_component<PositionComponent>(ev.shopPurchase.itemEID);
                [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 70.f}
                                  count:28 speed:380.f size:15.f
                                  color:(simd_float4){1.0f, 0.82f, 0.25f, 1.f}];
            }
            [_audio playUIClickSound];
        });

        _world.events().for_each(EventType::SecondWindUsed, [self](const Event& ev) {
            uint32_t pid = ev.secondWindUsed.playerID;
            if (_world.has_component<PositionComponent>(pid)) {
                const auto& p = _world.get_component<PositionComponent>(pid);
                [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 90.f}
                                  count:24 speed:360.f size:14.f
                                  color:(simd_float4){1.0f, 0.82f, 0.25f, 1.f}];
            }
            [_audio playRoomClearSound];
            [_renderer triggerDamageFlash];
        });

        _world.events().for_each(EventType::PlayerDowned, [self](const Event& ev) {
            _combo = 0;
            _comboTimer = 0.f;
            uint32_t pid = ev.playerDowned.playerID;
            if (_world.has_component<PositionComponent>(pid)) {
                const auto& p = _world.get_component<PositionComponent>(pid);
                [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 80.f}
                                  count:14 speed:220.f size:12.f
                                  color:(simd_float4){0.45f, 0.48f, 0.55f, 1.f}];
            }
            [_audio playHurtSound];
            [_renderer triggerDamageFlash];
        });

        _world.events().for_each(EventType::PlayerRevived, [self](const Event& ev) {
            uint32_t pid = ev.playerRevived.playerID;
            if (_world.has_component<PositionComponent>(pid)) {
                const auto& p = _world.get_component<PositionComponent>(pid);
                [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 90.f}
                                  count:20 speed:360.f size:14.f
                                  color:(simd_float4){1.0f, 0.78f, 0.18f, 1.f}];
            }
            [_audio playRoomClearSound];
        });

        _world.events().for_each(EventType::Evaded, [self](const Event& ev) {
            uint32_t pid = ev.evaded.playerID;
            if (_world.has_component<PositionComponent>(pid)) {
                const auto& p = _world.get_component<PositionComponent>(pid);
                [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 90.f}
                                  count:10 speed:240.f size:9.f
                                  color:(simd_float4){0.55f, 0.85f, 1.0f, 1.f}];
            }
            [_audio playSwingSound];
        });

        _world.events().for_each(EventType::DamageDealt, [self](const Event& ev) {
            uint32_t tid = ev.damageDealt.targetID;
            if (_world.has_component<FactionComponent>(tid)) {
                FactionComponent::Type targetFaction = _world.get_component<FactionComponent>(tid).type;
                if (targetFaction == FactionComponent::Enemy) {
                    [self _recordEnemyDamage:ev.damageDealt.amount];
                } else if (targetFaction == FactionComponent::Player) {
                    [self _recordPlayerDamage:ev.damageDealt.amount];
                }
            }
            if (_world.player_tags().present(tid) &&
                _world.has_component<HealthComponent>(tid) &&
                _world.get_component<HealthComponent>(tid).current > 0) {
                [_audio playHurtSound];
                [_renderer triggerDamageFlash]; // in-shader red edge vignette
                if (self.onPlayerDamaged)
                    dispatch_async(dispatch_get_main_queue(), self.onPlayerDamaged);
            }
        });
        _renderer.comboCount = _combo;
        _renderer.scoreValue = _runStats.score;

        _world.events().for_each(EventType::FinalKill, [self](const Event& ev) {
            uint32_t killer = ev.finalKill.killerID;
            if (_world.has_component<PositionComponent>(killer)) {
                const auto& p = _world.get_component<PositionComponent>(killer);
                [_renderer beginFinalKillZoomAt:(simd_float3){p.x, p.y, 0.f}
                                       duration:_world.slow_motion_duration_seconds()];
            }
        });

        BOOL exitReached = NO;
        BOOL cursedExitReached = NO;
        uint8_t exitCurseType = 0;
        _world.events().for_each(EventType::ExitReached, [&exitReached, &cursedExitReached, &exitCurseType](const Event& ev) {
            exitReached = YES;
            cursedExitReached = ev.exitReached.cursed ? YES : NO;
            exitCurseType = ev.exitReached.curseType;
        });
        if (exitReached && _currentRoom + 1 < kNumRooms) {
            if (cursedExitReached)
                [self _applyCursePortalReward:exitCurseType];
            _currentRoom += 1;
            [self _loadRoom];
            [self _transitionToPhase:BrawlerGamePhasePlaying];
        }
    }

    // -----------------------------------------------------------------------
    // Phase state machine
    // -----------------------------------------------------------------------
    switch (_phase) {

        case BrawlerGamePhaseTitle: {
            InputState s0 = _world.current_input(0);
            if (_dodgePulse || s0.dodge)
                [self enterMetaShop];
            else if (_attackPulse || s0.attack || _pausePulse || _specialPulse)
                [self _transitionToPhase:BrawlerGamePhasePlayerSelect];
            break;
        }

        case BrawlerGamePhaseMetaShop: {
            _phaseTimer -= dt;
            if (_phaseTimer > 0.f) break;
            InputState s0 = _world.current_input(0);
            if (_pausePulse || _dodgePulse || s0.dodge) {
                [self exitMetaShop];
            } else if (_attackPulse || s0.attack) {
                [self buySelectedMetaUpgrade];
            } else if (s0.moveY > 0.35f) {
                [self metaShopMove:-1];
            } else if (s0.moveY < -0.35f) {
                [self metaShopMove:1];
            }
            break;
        }

        case BrawlerGamePhasePlayerSelect: {
            // attack pulse / A button → 1 player
            // dodge  pulse / B button → 2 players
            // Platform VCs may also call startGameWithPlayers: directly (macOS keys, iOS buttons).
            InputState s0 = _world.current_input(0);
            if (_attackPulse || s0.attack)
                [self startGameWithPlayers:1];
            else if (_dodgePulse || s0.dodge)
                [self startGameWithPlayers:2];
            break;
        }

        case BrawlerGamePhasePaused: {
            if (_pausePulse)
                [self _transitionToPhase:BrawlerGamePhasePlaying];
            break;
        }

        case BrawlerGamePhasePlaying: {
            if (_pausePulse) {
                [self _transitionToPhase:BrawlerGamePhasePaused];
                break;
            }
            // All enemies defeated → room clear.
            if ([self _allEnemiesDefeated]) {
                [self _transitionToPhase:BrawlerGamePhaseRoomClear];
                break;
            }
            // All players dead → lose a life.
            if ([self _allPlayersDying]) {
                _lives--;
                _renderer.livesRemaining = _lives;
                if (self.onPhaseChanged)
                    self.onPhaseChanged(_phase, _currentRoom + 1, _lives);
                if (_lives > 0) {
                    [self _loadRoom];
                    [self _transitionToPhase:BrawlerGamePhasePlaying];
                } else {
                    [self _transitionToPhase:BrawlerGamePhaseLose];
                }
            }
            break;
        }

        case BrawlerGamePhaseRoomClear: {
            _phaseTimer -= dt;
            if (_phaseTimer <= 0.f) {
                _runCoins += 3;
                if (_currentRoom + 1 >= kNumRooms) {
                    [self _transitionToPhase:BrawlerGamePhaseWin];
                } else {
                    // Each active player picks a perk before the next room.
                    _upgradePlayerIndex = 0;
                    [self _rollUpgradeChoices];
                    [self _transitionToPhase:BrawlerGamePhaseUpgrade];
                }
            }
            break;
        }

        case BrawlerGamePhaseUpgrade: {
            _phaseTimer -= dt;
            if (_phaseTimer > 0.f) break; // input grace window
            // Platform VCs may call chooseUpgrade: directly (keys/buttons);
            // the universal mapping is attack → choice 0, dodge → choice 1.
            InputState s0 = _world.current_input(0);
            if (_attackPulse || s0.attack)      [self chooseUpgrade:0];
            else if (_dodgePulse || s0.dodge)   [self chooseUpgrade:1];
            break;
        }

        case BrawlerGamePhaseWin:
        case BrawlerGamePhaseLose: {
            _phaseTimer -= dt;
            if (_phaseTimer <= 0.f)
                [self _transitionToPhase:BrawlerGamePhaseTitle]; // back to title, don't auto-restart
            break;
        }
    }

    _attackPulse = NO;
    _dodgePulse  = NO;
    _pausePulse  = NO;
    _specialPulse = NO;
}

- (void)drawInMTKView:(MTKView *)view {
    dispatch_semaphore_wait(_frameSemaphore, DISPATCH_TIME_FOREVER);

    CFTimeInterval now = CACurrentMediaTime();
    float dt = fminf((float)(now - _lastTime), 0.1f);
    _lastTime = now;
    if (self.fixedFrameDt > 0.f) dt = self.fixedFrameDt; // deterministic autotest

    [self advanceFrame:dt];

    id<MTLCommandBuffer> cmd = [_commandQueue commandBuffer];
    __block dispatch_semaphore_t sem = _frameSemaphore;
    [cmd addCompletedHandler:^(id<MTLCommandBuffer> _) {
        dispatch_semaphore_signal(sem);
    }];

    [_renderer drawWorld:&_world inView:view commandBuffer:cmd];
    [cmd commit];
}

@end
