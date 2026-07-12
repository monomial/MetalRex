#pragma once
#include <stdint.h>

static constexpr int kRexMaxPlayers = 4;
// 6 raptors + 1 T-Rex, exactly — no unused slots. An unconfigured slot
// defaults to moving=false, which the box-target flicker path in
// RailCameraSystem_update (update_targets) reads as "spawn a legacy popup
// box here," so any headroom beyond what's actually spawned in
// World::reset_m1_scene renders as a stray colored box with no dino behind
// it. Keep this equal to the real spawn count.
static constexpr int kM1MaxTargets = 7;

struct PositionComponent {
    float x = 0.f;
    float y = 0.f;
    float z = 0.f;
};

struct VelocityComponent {
    float vx = 0.f;
    float vy = 0.f;
    float vz = 0.f;
};

struct HealthComponent {
    int current = 1;
    int max = 1;
};

struct FactionComponent {
    enum Type : uint8_t { Player = 0, Enemy = 1 } type = Player;
};

struct PlayerTagComponent {
    bool    active = true;
    uint8_t playerIndex = 0;
};

struct ReticleComponent {
    uint8_t playerIndex = 0;
    bool active = false;
    bool gyroAvailable = false;
    bool stickOnlyAssist = true;
    bool overTarget = false;
    float x = 0.5f;
    float y = 0.5f;
    float smoothedGyroX = 0.f;
    float smoothedGyroY = 0.f;
    float gyroDriftX = 0.f;
    float gyroDriftY = 0.f;
    float stickSensitivityH = 0.f;
    float stickSensitivityV = 0.f;
    float gyroSensitivityH = 0.f;
    float gyroSensitivityV = 0.f;
    float smoothingAlpha = 0.f;
    float stillnessThreshold = 0.f;
    float fireFlashTime = 0.f; // counts down from kFireFlashDuration on fire; 0 = no flash
    float fireCooldown = 0.f;  // min time between shots — a held trigger fires
                               // at the cadence, not once per 120Hz tick
    uint32_t shotCount = 0;    // total shots fired — the renderer diffs this
                               // across frames to spawn tracer effects
};

struct TargetComponent {
    bool active = false;
    bool moving = false;
    bool wasHit = false;
    bool lastHitWasWeakPoint = false;
    uint8_t lastHitByPlayer = UINT8_MAX;
    float railDistance = 0.f;
    // Spawn-time lateral "lane" for this target — RailCameraSystem_update
    // recomputes lateralOffset every tick as baseLateralOffset plus a small
    // weave, so this is what actually keeps pursuers spread apart on screen
    // instead of every moving target converging on the same shared wobble.
    float baseLateralOffset = 0.f;
    float lateralOffset = 0.f;
    float verticalOffset = 0.f;
    float worldX = 0.f;
    float worldY = 0.f;
    float worldZ = 0.f;
    float halfWidth = 0.05f;
    float halfHeight = 0.07f;
    float screenX = 0.5f;
    float screenY = 0.5f;
    float screenHalfW = 0.05f;
    float screenHalfH = 0.07f;
    float weakPointHalfW = 0.f;
    float weakPointOffsetY = 0.f;
    float timerOffset = 0.f;
};

struct RailCameraState {
    float elapsed = 0.f;
    float distance = 0.f;
    float rawT = 0.f;
    float speed = 1.2f;
    float fovYRadians = 1.04719758f;
    float aspect = 16.f / 9.f;
    float nearZ = 0.1f;
    float farZ = 120.f;
    float positionX = 0.f;
    float positionY = 0.f;
    float positionZ = 0.f;
    float lookAtX = 0.f;
    float lookAtY = 0.f;
    float lookAtZ = 1.f;
    float rightX = 1.f;
    float rightY = 0.f;
    float rightZ = 0.f;
    float upX = 0.f;
    float upY = 1.f;
    float upZ = 0.f;
};

static constexpr int kMaxBones = 64;

enum class CharacterClipSlot : uint8_t {
    Idle    = 0,
    Walk    = 1,
    Run     = 2,
    Attack  = 3,
    Jump    = 4,
    Death   = 5,
    Count
};

struct AnimationComponent {
    CharacterClipSlot currentClip   = CharacterClipSlot::Idle;
    CharacterClipSlot requestedClip = CharacterClipSlot::Idle;
    float      clipTime  = 0.f;
    bool       looping   = true;
    bool       clipDone  = false;
    bool       dying     = false;

    CharacterClipSlot prevClip       = CharacterClipSlot::Idle;
    float      prevClipTime   = 0.f;
    float      blendRemaining = 0.f;
    float      deathFade      = 1.f;
    float      boneMatrices[kMaxBones][16];
};

enum class DinoBehaviorState : uint8_t {
    Dormant = 0,
    Approach,
    Hold,
    Tell,
    Attack,
    Interrupted,
    Retreat,
    Dying
};

enum class DinoInterruptOutcome : uint8_t {
    None = 0,
    Succeeded,
    Failed
};

// Title -> Playing is host-driven: World constructs in Playing with P1+P2
// active (test compatibility — the sim tests drive gameplay directly);
// the real render path calls World::enter_title() at launch, and players
// join by pressing fire (release-then-press edged, so a held trigger or
// the tvOS launch press can never skip the title).
enum class GamePhase : uint8_t {
    Title = 0,
    Playing,
};

enum class DinoSpecies : uint8_t {
    Velociraptor = 0,
    Trex,
    Count
};

enum class DinoScoreEvent : uint8_t {
    Hit = 0,
    WeakPointHit,
    InterruptSuccess,
    InterruptFail,
    TellMissed,
    MajorAttackPointHit,
    MajorAttackPerfect
};

struct DinoBehaviorComponent {
    bool active = false;
    bool activeInEncounter = false;
    // The level's boss (chart-driven species — see BossChartConfig): never
    // returns to the dormant pool, and its death completes the level.
    bool isBoss = false;
    // Arena-defense raptor (post-boss holdout — see ArenaSystem): loops
    // approach/attack/retreat until KILLED (like the boss, it re-approaches
    // instead of going dormant after a retreat), and once dead it stays dead
    // and frees its pool slot rather than recycling behind the jeep.
    bool arena = false;
    // Boss stays Dormant until the camera reaches this rail distance — the
    // act's finale arrives after the waves, not alongside them. 0 = present
    // from the start.
    float bossArrivalDistance = 0.f;
    // Boss escalation: 0 below 1/3 damage taken, 1 past it, 2 past 2/3 —
    // each phase shortens the hold before attacks and quickens the chase
    // (DinoBehaviorSystem applies the multipliers; the renderer tints the
    // boss progressively redder so the escalation reads at a glance).
    uint8_t ragePhase = 0;
    uint8_t targetIndex = 0;
    DinoSpecies species = DinoSpecies::Velociraptor;
    DinoBehaviorState state = DinoBehaviorState::Dormant;
    DinoInterruptOutcome lastOutcome = DinoInterruptOutcome::None;
    bool outcomeThisCycle = false;
    float stateTime = 0.f;
    // Rail-units/second the dino runs after the jeep during Approach. Must
    // exceed the camera speed to actually gain ground; the margin over camera
    // speed is the effective closing rate. Movement pauses during Tell/Attack.
    float chaseSpeed = 1.5f;
    // The dino stops closing and may attack once it is within this many
    // rail-units behind the jeep. Must stay > 1 (RailCameraSystem pins
    // anything closer than 1 unit as a safety net).
    float attackRange = 2.4f;
    uint32_t waveId = 0;
    uint8_t laneRole = 0;
    float spawnGap = 8.f;
    float holdDuration = 2.25f;
    float attackDelay = 0.f;
    float retreatDuration = 1.2f;
    float retreatGap = 8.f;
    // Shots to kill. At 0 the dino enters Dying. Raptors recycle after the
    // death fade; the T-Rex is the terminal boss and completes the level.
    int maxHealth = 3;
    int health = 3;
    // Brief tint flash on taking a hit (renderer reads this).
    float hitFlashTime = 0.f;
    float tellEndNormalized = 0.28f;
    float interruptStartNormalized = 0.18f;
    float interruptEndNormalized = 0.46f;
    float jumpReactionDuration = 0.35f;
    bool wasHitDuringTell = false;
    // Damage dealt to per-player health when this dino's attack
    // lands unopposed (DinoInterruptOutcome::Failed) — see PlayerHealthSystem.
    int attackDamage = 15;
};

static constexpr int kBossMajorAttackPointCount = 4;

// Per-boss-species table of the 4 major-attack hit points. Authored in the
// boss's OWN normalized body box (u right 0..1, v down 0..1; 0.5,0.5 = box
// center), NOT screen space: at runtime each point is placed inside the boss's
// live projected screen box (BossMajorAttackSystem), so the points ride the
// moving/animating dino. The same table drives the Preview portrait's marker
// reveal (portrait art must share the boss box's framing for the markers to
// line up). See BossMajorAttackPoints.h.
struct BossMajorAttackPoint {
    float u = 0.5f;
    float v = 0.5f;
    float hitRadius = 0.06f; // viewport-space hit radius once placed on the boss
};

// Boss "major attack" QTE — the ONLY way to damage a boss. Bosses are immune
// to normal fire (shooting them still scores/streaks); a boss flees once every
// chart-scripted major attack has resolved. Two-phase, copying the Jurassic
// Park arcade reference: an optional one-time PREVIEW portrait telegraphs where
// the 4 points sit, then the scene drops into slow motion and the 4 targets
// appear one-by-one ON THE LIVE BOSS (tracked to its projected screen box),
// each with a big->small closing ring, to be shot before the countdown
// expires. Lives on World as a single instance, not an ECS component — every
// system that reads it (ReticleSystem, BossMajorAttackSystem, RexRenderer)
// wants a clean World::major_attack() accessor, not a hunt for "whichever
// entity isBoss."
enum class MajorAttackPhase : uint8_t {
    Inactive = 0,
    Preview,  // static portrait, points reveal one-by-one (first QTE of a fight only)
    Live,     // slow-mo live view: staggered closing-ring targets, shootable, countdown runs
    Result,   // brief hold showing Perfect / damage before resuming (or fleeing)
};

// Per-point runtime for the Live phase. screenX/screenY are recomputed every
// tick from the boss's live projected screen box, so the points track the
// moving dino with no separate 3D projection. appear ramps 0->1 as the ring
// closes onto the spot; a point is shootable once it has begun appearing.
struct BossMajorAttackPointState {
    bool hit = false;
    float appear = 0.f;       // 0 = not yet spawned, ramps to 1 as the ring closes
    float screenX = 0.5f;     // viewport, y-up (matches ReticleComponent.x/y)
    float screenY = 0.5f;
    float hitRadius = 0.06f;
};

struct BossMajorAttackState {
    MajorAttackPhase phase = MajorAttackPhase::Inactive;
    // uint32_t, not EntityID: Components.h is included by World.h before
    // EntityID is declared there, so this stays in EntityID's own underlying
    // type rather than introducing an include-order dependency the other way.
    uint32_t bossEntity = UINT32_MAX;
    DinoSpecies species = DinoSpecies::Trex;
    bool showPortrait = false; // this instance runs the one-time Preview phase
    bool isFinal = false;      // last scripted QTE of the fight: boss flees when it resolves

    float previewDuration = 2.4f;
    float previewElapsed = 0.f;

    float countdownDuration = 6.0f;
    float timeRemaining = 0.f;
    float liveElapsed = 0.f;   // drives the staggered per-point appearance

    BossMajorAttackPointState points[kBossMajorAttackPointCount];
    uint8_t hitMask = 0;       // bit i = point i hit
    uint8_t hitCount = 0;

    bool resolved = false;     // 4/4 hit, or countdown expired
    bool wasPerfect = false;
    float resultHoldRemaining = 0.f;

    bool active() const { return phase != MajorAttackPhase::Inactive; }
};

// Camera/boss/animation run at this fraction of normal gameDt while a major
// attack is active (aiming and the countdown itself stay unscaled — see
// World::tick). Small enough that no in-flight Attack clip (~0.5-1.6s in this
// project) can reach clipDone within even the longest countdown: at this
// scale a 6s real-time countdown only advances ~0.48s of "boss time."
static constexpr float kMajorAttackSlowMoScale = 0.08f;
// Live-phase pacing: gap between each of the 4 targets appearing, and how long
// each target's ring takes to close. countdownDuration comfortably outlasts
// all four appearing (3 * stagger + appear).
static constexpr float kMajorAttackPointStagger = 0.55f;
static constexpr float kMajorAttackPointAppear = 0.5f;
static constexpr float kMajorAttackResultHold = 1.2f;
// After the FINAL scripted QTE resolves, the boss visibly flees for this long
// (full speed, still ticking) before the level completes.
static constexpr float kMajorAttackFleeDuration = 1.6f;

// Arena "stand your ground" section (post-boss): the rail camera stops and
// raptors rush in wave-by-wave from spread lanes/depths. A wave advances only
// once every raptor in it is dead (arena raptors loop-attack until killed);
// when the last wave clears, the level completes. Lives on World as a single
// instance, driven by ArenaSystem.
struct ArenaState {
    bool active = false;
    int waveIndex = -1; // -1 before the first wave spawns
    // WaitingToSpawn: counting down `timer` before the next wave.
    // InProgress: a wave is out; watching for it to be fully cleared.
    enum Phase : uint8_t { WaitingToSpawn = 0, InProgress } phase = WaitingToSpawn;
    float timer = 0.f;
};
static constexpr float kArenaFirstWaveDelay = 1.4f; // beat after the boss flees
static constexpr float kArenaInterWaveDelay = 2.0f; // breather between waves

// Per-player health/life state. Lives in World as slot-indexed storage,
// matching the reticle array, rather than as per-entity ECS state.
struct PlayerHealthState {
    int health = 100;
    int maxHealth = 100;
    float hitFlashTime = 0.f; // brief red screen flash on taking a hit
    // Post-hit grace window: without this, dinos whose attack windows happen
    // to land in the same tick (or the next) could stack damage from a
    // single moment of bad luck into an instant death. Sized to be longer
    // than one attack cycle so at most one hit registers per dino pass.
    float invulnTime = 0.f;
    // Arcade-style continue: a depleted player sits out until that player's
    // own fire press "inserts a coin" and restores their slot.
    bool sittingOut = false;
};

struct PlayerScoreState {
    int score = 0;
    int currentStreak = 0;
    int bestStreak = 0;
    int shotsFired = 0;
    int shotsHit = 0;
    int weakPointHits = 0;
    int interruptSuccesses = 0;
};
