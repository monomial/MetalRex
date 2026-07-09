#pragma once
#include <stdint.h>

static constexpr int kRexMaxPlayers = 4;
static constexpr int kM1MaxTargets = 6;

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
};

struct TargetComponent {
    bool active = false;
    bool moving = false;
    bool wasHit = false;
    float railDistance = 0.f;
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
    Idle = 0,
    Tell,
    Attack,
    Interrupted,
    Landed,
    Dying
};

enum class DinoInterruptOutcome : uint8_t {
    None = 0,
    Succeeded,
    Failed
};

enum class DinoSpecies : uint8_t {
    Velociraptor = 0,
    Trex,
    Count
};

struct DinoBehaviorComponent {
    bool active = false;
    uint8_t targetIndex = 0;
    DinoSpecies species = DinoSpecies::Velociraptor;
    DinoBehaviorState state = DinoBehaviorState::Idle;
    DinoInterruptOutcome lastOutcome = DinoInterruptOutcome::None;
    bool outcomeThisCycle = false;
    float stateTime = 0.f;
    // Minimum time back in the chase state before the next attack may
    // begin — even if the dino is already within attackRange.
    float idleDuration = 0.75f;
    // Rail-units/second the dino runs after the jeep during the
    // Idle/chase state. Must exceed the camera speed to actually gain
    // ground; the margin over camera speed is the effective closing rate.
    // Movement pauses during Tell/Attack/Interrupted/Landed.
    float chaseSpeed = 1.5f;
    // The dino stops closing and may attack once it is within this many
    // rail-units behind the jeep. Must stay > 1 (RailCameraSystem pins
    // anything closer than 1 unit as a safety net).
    float attackRange = 2.4f;
    // Shots to kill. At 0 the dino enters Dying: Death clip, screen-door
    // fade, then respawns deep behind the jeep with health restored.
    int maxHealth = 3;
    int health = 3;
    // Brief tint flash on taking a hit (renderer reads this).
    float hitFlashTime = 0.f;
    float tellEndNormalized = 0.28f;
    float interruptStartNormalized = 0.18f;
    float interruptEndNormalized = 0.46f;
    float jumpReactionDuration = 0.35f;
};
