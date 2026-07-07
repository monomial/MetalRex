#include "AnimationSystem.h"
#include "Simulation/World.h"
#include "Assets/CharacterLoader.h"
#include <math.h>

static const LoadedCharacter* s_playerChar = nullptr;
static const LoadedCharacter* s_enemyChar  = nullptr;

void AnimationSystem_set_characters(const LoadedCharacter* player,
                                    const LoadedCharacter* enemy) {
    s_playerChar = player;
    s_enemyChar  = enemy;
}

// Fallback clip durations used before character assets are loaded.
// These match the actual Mixamo clips we exported (idle 3.83s, walk 1.03s, etc.).
static const float kClipDurationFallback[(int)AnimClipID::Count] = {
    3.83f, // Idle    — looping
    1.03f, // Walk    — looping
    1.03f, // Attack  — one-shot
    1.50f, // Hurt    — one-shot
    4.50f, // Death   — one-shot
    2.40f, // Dodge   — one-shot (72 frames @ 30fps)
    1.03f, // Attack2 — one-shot combo finisher (31 frames @ 30fps)
    0.80f, // Run     — looping
};

static float clip_duration(const LoadedCharacter* charData, AnimClipID id) {
    if (charData && charData->clipLoaded[(int)id]) {
        float d = charData->clips[(int)id].duration();
        if (d > 0.f) return d;
    }
    return kClipDurationFallback[(int)id];
}

static bool clip_loops(AnimClipID id) {
    return id == AnimClipID::Idle || id == AnimClipID::Walk || id == AnimClipID::Run;
}

// Cross-fade length for every clip transition. Long enough to kill the visual
// pop, short enough not to soften attack startup.
static constexpr float kAnimBlendDuration = 0.1f;

// All clip changes go through here so the cross-fade bookkeeping and the
// clip-start events can't be forgotten at one of the transition sites.
static void begin_transition(World& world, EntityID id,
                             AnimationComponent& anim, AnimClipID next) {
    anim.prevClip       = anim.currentClip;
    anim.prevClipTime   = anim.clipTime;
    anim.blendRemaining = kAnimBlendDuration;
    anim.currentClip    = next;
    anim.clipTime       = 0.f;
    anim.clipDone       = false;
    anim.looping        = clip_loops(next);
}

static float clip_speed_multiplier(World& world, EntityID entity, AnimClipID id) {
    float mult = 1.f;
    switch (id) {
        case AnimClipID::Attack:  mult = 4.0f; break;
        case AnimClipID::Attack2: mult = 3.0f; break; // finisher lands a touch heavier
        case AnimClipID::Hurt:    mult = 2.0f; break;
        case AnimClipID::Dodge:   mult = 2.0f; break;
        case AnimClipID::Death:   mult = 2.0f; break;
        case AnimClipID::Run:     mult = 1.0f; break;
        default:                  mult = 1.0f; break;
    }
    return mult;
}

void AnimationSystem_update(World& world, float gameDt) {
    if (gameDt == 0.f) return; // frozen during HitStop

    uint32_t count = world.entity_count();
    for (EntityID id = 0; id < count; ++id) {
        if (!world.has_component<AnimationComponent>(id)) continue;
        AnimationComponent& anim = world.get_component<AnimationComponent>(id);

        // Resolve character data for accurate clip durations.
        const LoadedCharacter* charData = nullptr;
        if (world.has_component<FactionComponent>(id)) {
            auto t = world.get_component<FactionComponent>(id).type;
            charData = (t == FactionComponent::Player) ? s_playerChar : s_enemyChar;
        }

        float duration = clip_duration(charData, anim.currentClip);
        // Attack and Hurt play at 1.5× so punches feel snappy and hit reactions
        // are brief. Idle/Walk/Death keep normal speed.
        anim.clipTime += gameDt * clip_speed_multiplier(world, id, anim.currentClip);
        anim.clipDone  = false;

        if (clip_loops(anim.currentClip)) {
            // Looping clips transition immediately when any different clip is requested.
            if (anim.requestedClip != anim.currentClip) {
                begin_transition(world, id, anim, anim.requestedClip);
            } else if (anim.clipTime >= duration) {
                anim.clipTime = fmodf(anim.clipTime, duration);
            }
        } else {
            // Non-looping: play through fully, then allow transition.
            if (anim.clipTime >= duration) {
                anim.clipTime = duration;
                anim.clipDone = true;
                bool canTransition = !anim.dying || anim.requestedClip == AnimClipID::Death;
                if (canTransition && anim.requestedClip != anim.currentClip)
                    begin_transition(world, id, anim, anim.requestedClip);
            }
        }

        if (charData && charData->clipLoaded[(int)anim.currentClip]) {
            charData->clips[(int)anim.currentClip].sample(anim.clipTime, anim.boneMatrices);

            // Cross-fade: blend the frozen outgoing pose into the incoming clip.
            if (anim.blendRemaining > 0.f && charData->clipLoaded[(int)anim.prevClip]) {
                float prevPose[kMaxBones][16];
                charData->clips[(int)anim.prevClip].sample(anim.prevClipTime, prevPose);
                float w = anim.blendRemaining / kAnimBlendDuration; // 1 → 0
                for (int b = 0; b < kMaxBones; ++b)
                    for (int k = 0; k < 16; ++k)
                        anim.boneMatrices[b][k] =
                            anim.boneMatrices[b][k] * (1.f - w) + prevPose[b][k] * w;
            }
        }
        if (anim.blendRemaining > 0.f)
            anim.blendRemaining = anim.blendRemaining - gameDt < 0.f
                                ? 0.f : anim.blendRemaining - gameDt;
    }

    // Dissolve then destroy non-player entities whose death animation has
    // finished: the corpse fades out over kDeathFadeDuration instead of
    // popping out of existence the frame the clip ends.
    static constexpr float kDeathFadeDuration = 1.0f;
    for (EntityID id = 0; id < count; ++id) {
        if (!world.has_component<AnimationComponent>(id)) continue;
        if (world.player_tags().present(id)) continue; // player death handled by game loop
        AnimationComponent& anim = world.get_component<AnimationComponent>(id);
        if (anim.dying && anim.clipDone && anim.currentClip == AnimClipID::Death) {
            anim.deathFade -= gameDt / kDeathFadeDuration;
            if (anim.deathFade <= 0.f)
                world.defer_destroy(id);
        }
    }
}

void AnimationSystem_request_clip(World& world, EntityID entity, AnimClipID clip) {
    if (!world.has_component<AnimationComponent>(entity)) return;
    world.get_component<AnimationComponent>(entity).requestedClip = clip;
}

float AnimationSystem_clip_duration(World& world, EntityID entity, AnimClipID clip) {
    const LoadedCharacter* charData = nullptr;
    if (world.has_component<FactionComponent>(entity)) {
        auto t = world.get_component<FactionComponent>(entity).type;
        charData = (t == FactionComponent::Player) ? s_playerChar : s_enemyChar;
    }
    return clip_duration(charData, clip);
}
