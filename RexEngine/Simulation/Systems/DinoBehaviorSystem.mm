#include "DinoBehaviorSystem.h"
#include "Simulation/Systems/AnimationSystem.h"
#include <algorithm>

static float attack_progress(World& world, EntityID id, const AnimationComponent& anim) {
    float duration = AnimationSystem_clip_duration(world, id, CharacterClipSlot::Attack);
    if (duration <= 0.0001f) return 1.f;
    return std::clamp(anim.clipTime / duration, 0.f, 1.f);
}

static void enter_attack(World& world, EntityID id, DinoBehaviorComponent& dino) {
    dino.state = DinoBehaviorState::Tell;
    dino.stateTime = 0.f;
    dino.lastOutcome = DinoInterruptOutcome::None;
    dino.outcomeThisCycle = false;
    if (dino.targetIndex < kM1MaxTargets) {
        world.target(dino.targetIndex).wasHit = false;
    }
    AnimationSystem_request_clip(world, id, CharacterClipSlot::Attack);
}

static void enter_idle(World& world, EntityID id, DinoBehaviorComponent& dino) {
    dino.state = DinoBehaviorState::Idle;
    dino.stateTime = 0.f;
    // Force, not request: reached from Interrupted's jumpReactionDuration
    // timeout, which (at the default 0.35s vs. Jump's own ~0.70s fallback
    // duration) fires WHILE Jump is still playing. A graceful request would
    // silently queue behind Jump finishing on its own, so the dino would
    // keep playing the reaction well after the state machine already moved
    // on to Idle.
    AnimationSystem_force_clip(world, id, CharacterClipSlot::Idle);
}

void DinoBehaviorSystem_update(World& world, float gameDt) {
    if (gameDt == 0.f) return;

    uint32_t count = world.entity_count();
    for (EntityID id = 0; id < count; ++id) {
        if (!world.has_component<DinoBehaviorComponent>(id)) continue;
        DinoBehaviorComponent& dino = world.get_component<DinoBehaviorComponent>(id);
        if (!dino.active) continue;

        dino.stateTime += gameDt;
        AnimationComponent* anim = world.has_component<AnimationComponent>(id)
                                 ? &world.get_component<AnimationComponent>(id) : nullptr;

        switch (dino.state) {
            case DinoBehaviorState::Idle:
                if (dino.stateTime >= dino.idleDuration) {
                    enter_attack(world, id, dino);
                }
                break;

            case DinoBehaviorState::Tell:
            case DinoBehaviorState::Attack: {
                if (!anim) {
                    dino.lastOutcome = DinoInterruptOutcome::Failed;
                    dino.outcomeThisCycle = true;
                    dino.state = DinoBehaviorState::Landed;
                    dino.stateTime = 0.f;
                    break;
                }

                float progress = attack_progress(world, id, *anim);
                if (progress >= dino.tellEndNormalized && dino.state == DinoBehaviorState::Tell) {
                    dino.state = DinoBehaviorState::Attack;
                    dino.stateTime = 0.f;
                }

                bool inWindow = progress >= dino.interruptStartNormalized
                             && progress <= dino.interruptEndNormalized;
                bool hit = dino.targetIndex < kM1MaxTargets
                        && world.target(dino.targetIndex).wasHit;
                if (hit && inWindow) {
                    world.target(dino.targetIndex).wasHit = false;
                    dino.lastOutcome = DinoInterruptOutcome::Succeeded;
                    dino.outcomeThisCycle = true;
                    dino.state = DinoBehaviorState::Interrupted;
                    dino.stateTime = 0.f;
                    // Force, not request: Attack hasn't finished (that's the
                    // whole point of an interrupt), and the graceful request
                    // path waits for a non-looping clip to finish on its own
                    // before switching — which would silently swallow the
                    // interrupt and let Attack play out anyway.
                    AnimationSystem_force_clip(world, id, CharacterClipSlot::Jump);
                    break;
                }

                if (anim->clipDone && anim->currentClip == CharacterClipSlot::Attack) {
                    dino.lastOutcome = DinoInterruptOutcome::Failed;
                    dino.outcomeThisCycle = true;
                    dino.state = DinoBehaviorState::Landed;
                    dino.stateTime = 0.f;
                    break;
                }
                break;
            }

            case DinoBehaviorState::Interrupted:
                if ((anim && anim->clipDone && anim->currentClip == CharacterClipSlot::Jump)
                    || dino.stateTime >= dino.jumpReactionDuration) {
                    enter_idle(world, id, dino);
                }
                break;

            case DinoBehaviorState::Landed:
                enter_idle(world, id, dino);
                break;
        }
    }
}

