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

static void enter_chase(World& world, EntityID id, DinoBehaviorComponent& dino) {
    dino.state = DinoBehaviorState::Idle;
    dino.stateTime = 0.f;
    // The Idle state is the chase phase: the dino runs after the jeep
    // (see the Idle case below), so it plays Run, not Idle.
    // Force, not request: reached from Interrupted's jumpReactionDuration
    // timeout, which (at the default 0.35s vs. Jump's own ~0.70s fallback
    // duration) fires WHILE Jump is still playing. A graceful request would
    // silently queue behind Jump finishing on its own, so the dino would
    // keep playing the reaction well after the state machine already moved
    // on.
    AnimationSystem_force_clip(world, id, CharacterClipSlot::Run);
}

static void respawn(World& world, EntityID id, DinoBehaviorComponent& dino) {
    dino.health = dino.maxHealth;
    dino.hitFlashTime = 0.f;
    if (world.has_component<AnimationComponent>(id)) {
        world.get_component<AnimationComponent>(id).deathFade = 1.f;
    }
    if (dino.targetIndex < kM1MaxTargets) {
        TargetComponent& target = world.target(dino.targetIndex);
        target.railDistance = std::max(0.f, world.rail_camera().distance - 9.f);
        target.wasHit = false;
    }
    enter_chase(world, id, dino);
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

        // Consume this tick's hit (ReticleSystem sets target.wasHit on a
        // successful shot). Every hit does damage; whether it ALSO
        // interrupts an attack depends on the interrupt window below.
        bool wasShot = false;
        if (dino.targetIndex < kM1MaxTargets) {
            TargetComponent& target = world.target(dino.targetIndex);
            if (target.wasHit) {
                wasShot = true;
                target.wasHit = false;
            }
        }
        if (dino.hitFlashTime > 0.f) {
            dino.hitFlashTime = std::max(0.f, dino.hitFlashTime - gameDt);
        }
        if (wasShot && dino.state != DinoBehaviorState::Dying) {
            dino.health -= 1;
            dino.hitFlashTime = 0.2f;
            if (dino.health <= 0) {
                dino.state = DinoBehaviorState::Dying;
                dino.stateTime = 0.f;
                // Force: death must cut through whatever is playing,
                // including a mid-flight Attack.
                AnimationSystem_force_clip(world, id, CharacterClipSlot::Death);
                continue;
            }
        }

        switch (dino.state) {
            case DinoBehaviorState::Idle: {
                // Chase phase: the dino runs after the jeep from behind
                // (the camera rides the rail forward, facing backward).
                // Increasing railDistance closes the gap; the dino gains
                // only because its chaseSpeed exceeds the jeep's speed.
                // It stops closing at attackRange — never overrunning the
                // jeep — and attacks from there once idleDuration has
                // elapsed. If it drops too far back, RailCameraSystem
                // recycles it closer as a fresh pursuer.
                if (dino.targetIndex < kM1MaxTargets) {
                    TargetComponent& target = world.target(dino.targetIndex);
                    float gap = std::max(0.f, world.rail_camera().distance - target.railDistance);
                    if (gap > dino.attackRange && dino.chaseSpeed > 0.f) {
                        target.railDistance += std::min(dino.chaseSpeed * gameDt,
                                                        gap - dino.attackRange);
                    }
                    if (gap <= dino.attackRange && dino.stateTime >= dino.idleDuration) {
                        enter_attack(world, id, dino);
                        break;
                    }
                }
                // Covers initial spawn (AnimationComponent defaults to the
                // Idle clip); a same-clip request is a no-op afterwards.
                AnimationSystem_request_clip(world, id, CharacterClipSlot::Run);
                break;
            }

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
                if (wasShot && inWindow) {
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
                    enter_chase(world, id, dino);
                }
                break;

            case DinoBehaviorState::Landed:
                enter_chase(world, id, dino);
                break;

            case DinoBehaviorState::Dying: {
                if (!anim) {
                    respawn(world, id, dino);
                    break;
                }
                // Death clip plays through, then the corpse dissolves
                // (renderer feeds deathFade to the shader's screen-door
                // discard), then the dino respawns deep behind the jeep as
                // a fresh pursuer. anim->dying is deliberately NOT set:
                // that flag routes into AnimationSystem's fade-and-destroy
                // path, and these entities are permanent — they recycle.
                bool deathDone = anim->clipDone
                              && anim->currentClip == CharacterClipSlot::Death;
                if (deathDone) {
                    anim->deathFade -= gameDt / 0.8f;
                    if (anim->deathFade <= 0.f) {
                        respawn(world, id, dino);
                    }
                }
                break;
            }
        }
    }
}

