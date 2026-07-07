#pragma once
#include <stdint.h>

// All component structs for MetalBrawler.
// Rules: plain C structs only. No methods. No logic. Only data.
// Adding a new component: add struct here, add storage member to World, add
// _pool<T>() specialization in World.mm.

// --- Spatial ---

struct PositionComponent {
    float x, y, z;
};

struct VelocityComponent {
    float vx, vy, vz;
};

// --- Game state ---

struct HealthComponent {
    int current;
    int max;
};

struct DownedComponent {
    float reviveProgress = 0.f;
};

// Which side this entity is on — used by AI and CombatSystem.
struct FactionComponent {
    enum Type : uint8_t { Player = 0, Enemy = 1 } type;
};

// Tag — marks a player-controlled entity.
// playerIndex (0–3) maps to World::_inputs[playerIndex] for input routing.
struct PlayerTagComponent {
    bool    active;      // padding; presence in storage is the real signal
    uint8_t playerIndex; // 0 = P1, 1 = P2, 2 = P3, 3 = P4
};

// Last non-zero movement direction, kept as a normalized 2D vector.
// Updated by InputSystem whenever the player moves; used by CombatSystem
// to restrict the punch hitbox to a forward arc.
// Default (0, 1) matches the renderer's default facing (+Y = up the screen).
struct FacingComponent {
    float dx = 0.f, dy = 1.f;
};

// ---------------------------------------------------------------------------
// Animation
// ---------------------------------------------------------------------------

static constexpr int kMaxBones = 64;

// Which animation clip is playing. Matches the clip names exported from Mixamo.
// NOTE: when adding a clip, update ALL of: kClipDurationFallback +
// clip_speed_multiplier (AnimationSystem.mm), kAttackWindows (CombatSystem.mm),
// and the clips array in BrawlerGameDelegate._loadCharacters. Missing entries
// aggregate-initialize to 0 (a zero-length clip with no hitbox) — silently.
enum class AnimClipID : uint8_t {
    Idle    = 0,
    Walk    = 1,
    Attack  = 2,
    Hurt    = 3,
    Death   = 4,
    Dodge   = 5,
    Attack2 = 6, // combo finisher — chained from Attack via comboQueued
    Run     = 7,
    Count
};

// Drives AnimationSystem. Holds per-entity clip state + GPU bone matrices.
// float4x4 bone matrices are written by AnimationSystem and uploaded to the
// GPU skinning uniform buffer each frame.
struct AnimationComponent {
    AnimClipID currentClip   = AnimClipID::Idle;
    AnimClipID requestedClip = AnimClipID::Idle; // set by other systems to request a transition
    float      clipTime  = 0.f;  // seconds since clip start
    bool       looping   = true;
    bool       clipDone  = false; // true on last frame of a non-looping clip
    bool       dying      = false; // entity is playing death animation; pending destruction
    bool       hitApplied = false; // damage already dealt this swing; cleared on new attack
    bool       comboQueued = false; // attack pressed during the Attack clip's chain
                                    // window → chain into Attack2 at clip end
    // Cross-fade: on every clip transition the outgoing pose is frozen and
    // blended into the incoming clip over kAnimBlendDuration seconds.
    AnimClipID prevClip       = AnimClipID::Idle;
    float      prevClipTime   = 0.f; // frozen sample time of the outgoing clip
    float      blendRemaining = 0.f; // seconds of cross-fade left (0 = no blend)
    // Death dissolve: after the death clip finishes the corpse fades 1 → 0
    // (screen-door dissolve in the shader) before the entity is destroyed.
    float      deathFade      = 1.f;
    float      boneMatrices[kMaxBones][16]; // column-major float4x4 per bone
};

// ---------------------------------------------------------------------------
// Damage cooldown (contact/hazard sources)
// ---------------------------------------------------------------------------

// Prevents rapid-fire damage from area/contact sources.
// HazardSystem and ContactDamageSystem skip the entity while remaining > 0.
struct DamageCooldownComponent {
    float remaining; // seconds until next hit is allowed
};

// Per-enemy cooldown between attack initiations. Decremented by EnemyAISystem
// each tick; when it reaches 0 the enemy may begin a new Attack clip.
struct EnemyAttackCooldownComponent {
    float remaining = 0.f; // seconds until next attack is allowed (0 = ready)
    float windup    = 0.f; // seconds left before the committed Attack clip starts
    uint8_t shotCount = 0; // deterministic ranged-shot counter for Spitter lobs
};

// Marks a boss enemy. CombatSystem uses this to suppress most hurt reactions.
struct BossTagComponent {
    bool active = true; // presence in storage is the real signal
};

// Ground hazard (lava snake): deals passive area damage to players inside
// `radius`, gated by their DamageCooldownComponent. Despawns after lifetime.
// Hazards are NOT killable and carry no FactionComponent (so the AI, combat,
// and room-clear logic all ignore them).
struct HazardComponent {
    float radius   = 70.f;
    int   damage   = 1;
    float lifetime = 6.f; // seconds until despawn
};

struct LavaLobComponent {
    float startX = 0.f;
    float startY = 0.f;
    float destX = 0.f;
    float destY = 0.f;
    float elapsed = 0.f;
    float duration = 1.1f;
    int poolDamage = 1;
    float poolRadius = 80.f;
    float poolLifetime = 3.5f;
};

struct HeartPickupComponent {
    float lifetime = 8.f;
};

struct ScrapPickupComponent {
    int value = 2;
    float lifetime = 12.f;
};

struct ExitComponent {
    bool active = true;
    bool cursed = false;
    uint8_t curseType = 0;
};

struct ProjectileComponent {
    float vx = 0.f;
    float vy = 0.f;
    int damage = 1;
    float lifetime = 2.5f;
    float homing = 0.f;
    float homingTime = 0.f;
};

struct TelegraphLineComponent {
    float x2 = 0.f;
    float y2 = 0.f;
    float width = 18.f;
    float aimX = 0.f;
    float aimY = 1.f;
};

struct LeaperComponent {
    uint8_t state = 0; // 0 Walk, 1 Telegraph, 2 Leap, 3 Recover
    float timer = 0.f;
    float startX = 0.f;
    float startY = 0.f;
    float destX = 0.f;
    float destY = 0.f;
    float cooldown = 0.f;
};

struct PendingSpawn {
    uint8_t archetype = 0;
    uint8_t wave = 0;
    float x = 0.f;
    float y = 0.f;
};

struct WaveControllerComponent {
    PendingSpawn spawns[16] = {};
    int spawnCount = 0;
    int waveCount = 0;
    int currentWave = 0;
    float timer = 0.f;
    uint8_t phase = 0; // 0 InitialDelay, 1 Telegraph, 2 Fighting, 3 Done
    bool bossMode = false;
    int bossMinionCap = 3;
    PendingSpawn reinforcements[8] = {};
    int reinforceCount = 0;
};

struct SpawnMarkerComponent {
    uint8_t archetype = 0;
    float countdown = 0.f;
    uint8_t style = 0; // 0 ground-rise, 1 sky-drop
};

struct SpawnAnimComponent {
    float progress = 0.f; // 0..1 over kSpawnAnimDuration
    uint8_t style = 0;   // 0 ground-rise, 1 sky-drop
};

struct ObstacleComponent {
    float halfW = 30.f;
    float halfH = 30.f;
};

struct BoxComponent {
    bool hasScrap = true;
};

struct ShopkeeperComponent {
    bool active = true;
};

struct ShopItemComponent {
    uint8_t perkID = 0;
    int price = 25;
    bool prevAttack[4] = {};
};

struct ChargeAttackComponent {
    float held = 0.f;
    bool charging = false;
    bool prevAttack = false;
};

// Looping waypoint path. HazardSystem moves the entity along the closed
// polyline pts[0..count-1] → pts[0] at `speed`, wrapping forever.
struct PathFollowComponent {
    float   pts[4][2] = {};
    uint8_t count     = 0;
    float   distance  = 0.f;   // distance traveled along the loop
    float   speed     = 300.f; // units/sec
};

// Boss charge-attack state machine, driven by BossSystem (runs after
// EnemyAISystem and overrides its velocity/clip while not Idle).
struct BossChargeComponent {
    enum State : uint8_t { Idle = 0, Telegraph = 1, Charge = 2, Recover = 3, Leap = 4 };
    enum Ability : uint8_t { AbilityCharge = 0, AbilityLobVolley = 1, AbilityLeap = 2 };
    uint8_t state = Idle;
    uint8_t ability = AbilityCharge;
    uint8_t abilityCounter = 0;
    bool    enraged = false;
    float   timer = 4.f;  // Idle: until next charge; other states: time left
    float   dirX  = 0.f;  // locked charge direction
    float   dirY  = 1.f;
    float   destX = 0.f;
    float   destY = 0.f;
    float   startX = 0.f;
    float   startY = 0.f;
    float   leapDuration = 0.45f;
};

// Run-level player stat modifiers from between-room perk choices. Applied to
// player entities at spawn from BrawlerGameDelegate's run state (the World is
// rebuilt every room, so the run-level truth lives in the delegate).
struct StatsComponent {
    int   damageBonus       = 0;   // added to attack damage
    float speedMult         = 1.f; // multiplies move speed
    float knockbackMult     = 1.f; // multiplies outgoing shove velocity
    float dodgeCooldownMult = 1.f; // multiplies dodge-charge regeneration time
    float dodgeChance       = 0.f; // passive chance to negate incoming damage
    float specialChargeMult = 1.f; // multiplies meter gained from landed hits
    int   secondWinds       = 0;   // one-time saves at 1 HP before death
    int   lifestealPerHits  = 0;   // 0 = off, otherwise heal after N landed hits
    bool  thorns            = false;
    bool  whirlwind         = false;
    bool  passiveSpecial    = false;
    int   hitsSinceHeal     = 0;
};

struct SpecialMeterComponent {
    float charge = 0.f; // 0..1 radial slam meter
};

// Shove applied to an entity that just took a hit. KnockbackSystem owns the
// entity's velocity while this is present (same ownership trick as Dodge):
// linear decay from the initial impulse to zero over `duration` seconds,
// then the component is removed. Added by CombatSystem on hit.
struct KnockbackComponent {
    float velX     = 0.f; // initial impulse velocity (direction * speed)
    float velY     = 0.f;
    float elapsed  = 0.f; // seconds since the hit
    float duration = 0.f; // total knockback time
};

// Present on a player entity for the duration of a dodge roll.
// Presence = invincible: CombatSystem skips damage to any entity that has this.
// Added and removed entirely by DodgeSystem — do not add manually.
struct DodgeComponent {
    bool  active = false; // velocity has been initialised
    float velX   = 0.f;  // initial velocity at dodge start (direction * kDodgeSpeed)
    float velY   = 0.f;  // stored so deceleration curve uses a consistent direction
    float elapsed = 0.f; // seconds since this charge's dodge started
};

struct DodgeChargesComponent {
    int charges = 2;
    int maxCharges = 2;
    float regenTimer = 0.f;
};
