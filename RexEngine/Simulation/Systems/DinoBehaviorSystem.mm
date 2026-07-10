#include "DinoBehaviorSystem.h"
#include "Simulation/Systems/AnimationSystem.h"
#include <algorithm>
#include <math.h>

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
    dino.wasHitDuringTell = false;
    if (dino.targetIndex < kM1MaxTargets) {
        TargetComponent& target = world.target(dino.targetIndex);
        target.wasHit = false;
        target.lastHitWasWeakPoint = false;
        target.lastHitByPlayer = UINT8_MAX;
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
        target.lastHitWasWeakPoint = false;
        target.lastHitByPlayer = UINT8_MAX;
    }
    enter_chase(world, id, dino);
}

static void emit_hit_score(World& world, uint8_t playerIndex, DinoSpecies species, bool weakPoint) {
    if (playerIndex >= kRexMaxPlayers) return;
    world.events().push_dino_score(playerIndex,
                                   weakPoint ? DinoScoreEvent::WeakPointHit : DinoScoreEvent::Hit,
                                   species);
}

static int nearest_damage_target_player(World& world, const TargetComponent& target) {
    int bestPlayer = -1;
    float bestDistSq = 0.f;
    for (int p = 0; p < kRexMaxPlayers; ++p) {
        const ReticleComponent& reticle = world.reticle(p);
        if (!reticle.active || world.player_health(p).sittingOut) continue;

        float dx = reticle.x - target.screenX;
        float dy = reticle.y - target.screenY;
        float distSq = dx * dx + dy * dy;
        if (bestPlayer < 0 || distSq < bestDistSq) {
            bestPlayer = p;
            bestDistSq = distSq;
        }
    }
    return bestPlayer;
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
        bool shotWasWeakPoint = false;
        uint8_t shotPlayer = UINT8_MAX;
        if (dino.targetIndex < kM1MaxTargets) {
            TargetComponent& target = world.target(dino.targetIndex);
            if (target.wasHit) {
                wasShot = true;
                shotWasWeakPoint = target.lastHitWasWeakPoint;
                shotPlayer = target.lastHitByPlayer;
                target.wasHit = false;
                target.lastHitWasWeakPoint = false;
                target.lastHitByPlayer = UINT8_MAX;
            }
        }
        if (dino.hitFlashTime > 0.f) {
            dino.hitFlashTime = std::max(0.f, dino.hitFlashTime - gameDt);
        }
        if (wasShot && dino.state != DinoBehaviorState::Dying) {
            dino.health -= 1;
            dino.hitFlashTime = 0.2f;
            if (dino.health <= 0) {
                emit_hit_score(world, shotPlayer, dino.species, shotWasWeakPoint);
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
                if (wasShot) {
                    emit_hit_score(world, shotPlayer, dino.species, shotWasWeakPoint);
                }
                // Chase phase: the dino runs after the jeep from behind
                // (the camera rides the rail forward, facing backward).
                // Increasing railDistance closes the gap; the dino gains
                // only because its chaseSpeed exceeds the jeep's speed. Once
                // within attackRange it stops closing further but keeps
                // pace with the jeep's own speed — running alongside for
                // the rest of idleDuration rather than freezing in place,
                // which used to let the jeep quietly pull away again (gap
                // drifting back past attackRange) during the wait, before
                // the dino ever got to lunge. If it drops too far back
                // anyway, RailCameraSystem recycles it closer as a fresh
                // pursuer.
                if (dino.targetIndex < kM1MaxTargets) {
                    TargetComponent& target = world.target(dino.targetIndex);
                    float cameraSpeed = world.rail_camera().speed;
                    float gap = std::max(0.f, world.rail_camera().distance - target.railDistance);
                    if (gap > dino.attackRange && dino.chaseSpeed > 0.f) {
                        target.railDistance += std::min(dino.chaseSpeed * gameDt,
                                                        gap - dino.attackRange);
                    } else if (gap <= dino.attackRange) {
                        target.railDistance += cameraSpeed * gameDt;
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
                if (wasShot && dino.state == DinoBehaviorState::Tell) {
                    dino.wasHitDuringTell = true;
                }
                if (!anim) {
                    dino.lastOutcome = DinoInterruptOutcome::Failed;
                    dino.outcomeThisCycle = true;
                    dino.state = DinoBehaviorState::Landed;
                    dino.stateTime = 0.f;
                    int missedPlayer = -1;
                    if (dino.targetIndex < kM1MaxTargets) {
                        missedPlayer = nearest_damage_target_player(world, world.target(dino.targetIndex));
                    }
                    world.events().push_dino_score((uint8_t)missedPlayer,
                                                   DinoScoreEvent::InterruptFail,
                                                   dino.species);
                    break;
                }

                float progress = attack_progress(world, id, *anim);
                if (progress >= dino.tellEndNormalized && dino.state == DinoBehaviorState::Tell) {
                    if (!dino.wasHitDuringTell && dino.targetIndex < kM1MaxTargets) {
                        int missedPlayer = nearest_damage_target_player(world, world.target(dino.targetIndex));
                        world.events().push_dino_score((uint8_t)missedPlayer,
                                                       DinoScoreEvent::TellMissed,
                                                       dino.species);
                    }
                    dino.state = DinoBehaviorState::Attack;
                    dino.stateTime = 0.f;
                }

                bool inWindow = progress >= dino.interruptStartNormalized
                             && progress <= dino.interruptEndNormalized;
                if (wasShot && inWindow) {
                    dino.lastOutcome = DinoInterruptOutcome::Succeeded;
                    dino.outcomeThisCycle = true;
                    world.events().push_dino_score(shotPlayer,
                                                   DinoScoreEvent::InterruptSuccess,
                                                   dino.species);
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
                if (wasShot) {
                    emit_hit_score(world, shotPlayer, dino.species, shotWasWeakPoint);
                }

                if (anim->clipDone && anim->currentClip == CharacterClipSlot::Attack) {
                    dino.lastOutcome = DinoInterruptOutcome::Failed;
                    dino.outcomeThisCycle = true;
                    dino.state = DinoBehaviorState::Landed;
                    dino.stateTime = 0.f;
                    // The attack finished without being interrupted — it
                    // landed. World::damage_player applies its own
                    // invulnerability gate, so a wave of dinos finishing
                    // their attacks in the same tick doesn't all connect.
                    if (dino.targetIndex < kM1MaxTargets) {
                        int damagedPlayer = nearest_damage_target_player(world, world.target(dino.targetIndex));
                        world.events().push_dino_score((uint8_t)damagedPlayer,
                                                       DinoScoreEvent::InterruptFail,
                                                       dino.species);
                        if (damagedPlayer >= 0) {
                            world.damage_player(damagedPlayer, dino.attackDamage);
                        }
                    }
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
