#pragma once
#include <stdint.h>

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
    float x = 0.5f;
    float y = 0.5f;
};

static constexpr int kMaxBones = 64;

enum class AnimClipID : uint8_t {
    Idle    = 0,
    Walk    = 1,
    Attack  = 2,
    Hurt    = 3,
    Death   = 4,
    Dodge   = 5,
    Attack2 = 6,
    Run     = 7,
    Count
};

struct AnimationComponent {
    AnimClipID currentClip   = AnimClipID::Idle;
    AnimClipID requestedClip = AnimClipID::Idle;
    float      clipTime  = 0.f;
    bool       looping   = true;
    bool       clipDone  = false;
    bool       dying     = false;

    AnimClipID prevClip       = AnimClipID::Idle;
    float      prevClipTime   = 0.f;
    float      blendRemaining = 0.f;
    float      deathFade      = 1.f;
    float      boneMatrices[kMaxBones][16];
};
