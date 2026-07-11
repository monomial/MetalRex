#include "DinoBehaviorSystem.h"
#include "Simulation/Systems/AnimationSystem.h"
#include "Simulation/Systems/ScreenShakeSystem.h"
#include <algorithm>
#include <math.h>

static float attack_progress(World& world, EntityID id, const AnimationComponent& anim) {
    float duration = AnimationSystem_clip_duration(world, id, CharacterClipSlot::Attack);
    if (duration <= 0.0001f) return 1.f;
    return std::clamp(anim.clipTime / duration, 0.f, 1.f);
}

static void clear_target_hit(TargetComponent& target) {
    target.wasHit = false;
    target.lastHitWasWeakPoint = false;
    target.lastHitByPlayer = UINT8_MAX;
}

static void enter_dormant(World& world, EntityID id, DinoBehaviorComponent& dino) {
    dino.activeInEncounter = false;
    dino.state = DinoBehaviorState::Dormant;
    dino.stateTime = 0.f;
    dino.lastOutcome = DinoInterruptOutcome::None;
    dino.outcomeThisCycle = false;
    dino.wasHitDuringTell = false;
    if (dino.targetIndex < kM1MaxTargets) {
        TargetComponent& target = world.target(dino.targetIndex);
        target.active = false;
        clear_target_hit(target);
    }
    AnimationSystem_force_clip(world, id, CharacterClipSlot::Run);
}

static void enter_approach(World& world, EntityID id, DinoBehaviorComponent& dino) {
    dino.activeInEncounter = true;
    dino.state = DinoBehaviorState::Approach;
    dino.stateTime = 0.f;
    dino.lastOutcome = DinoInterruptOutcome::None;
    dino.outcomeThisCycle = false;
    dino.wasHitDuringTell = false;
    if (dino.targetIndex < kM1MaxTargets) {
        TargetComponent& target = world.target(dino.targetIndex);
        target.active = true;
        target.moving = true;
        clear_target_hit(target);
    }
    AnimationSystem_force_clip(world, id, CharacterClipSlot::Run);
}

static void enter_hold(World& world, EntityID id, DinoBehaviorComponent& dino) {
    dino.state = DinoBehaviorState::Hold;
    dino.stateTime = 0.f;
    AnimationSystem_request_clip(world, id, CharacterClipSlot::Run);
}

static void enter_attack(World& world, EntityID id, DinoBehaviorComponent& dino) {
    dino.state = DinoBehaviorState::Tell;
    dino.stateTime = 0.f;
    dino.lastOutcome = DinoInterruptOutcome::None;
    dino.outcomeThisCycle = false;
    dino.wasHitDuringTell = false;
    if (dino.targetIndex < kM1MaxTargets) {
        clear_target_hit(world.target(dino.targetIndex));
    }
    AnimationSystem_request_clip(world, id, CharacterClipSlot::Attack);
}

static void enter_retreat(World& world, EntityID id, DinoBehaviorComponent& dino) {
    dino.state = DinoBehaviorState::Retreat;
    dino.stateTime = 0.f;
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
        target.railDistance = std::max(0.f, world.rail_camera().distance - dino.retreatGap);
        clear_target_hit(target);
    }
    if (dino.isBoss) {
        enter_approach(world, id, dino);
    } else {
        enter_dormant(world, id, dino);
    }
}

static void complete_boss_death(World& world, DinoBehaviorComponent& dino) {
    dino.active = false;
    dino.activeInEncounter = false;
    if (dino.targetIndex < kM1MaxTargets) {
        TargetComponent& target = world.target(dino.targetIndex);
        target.active = false;
        clear_target_hit(target);
    }
    world.complete_level();
}

static void emit_hit_score(World& world, uint8_t playerIndex, DinoSpecies species, bool weakPoint,
                           const TargetComponent& target) {
    if (playerIndex >= kRexMaxPlayers) return;
    world.events().push_dino_score(playerIndex,
                                   weakPoint ? DinoScoreEvent::WeakPointHit : DinoScoreEvent::Hit,
                                   species, target.screenX, target.screenY);
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

static int activate_raptor_wave(World& world,
                                const RaptorWaveChartPayload& wave,
                                uint32_t waveId) {
    int activated = 0;
    const RailCameraState& camera = world.rail_camera();
    for (EntityID id = 0; id < world.entity_count() && activated < wave.groupSize; ++id) {
        if (!world.has_component<DinoBehaviorComponent>(id)) continue;
        DinoBehaviorComponent& dino = world.get_component<DinoBehaviorComponent>(id);
        if (dino.species != DinoSpecies::Velociraptor || dino.isBoss) continue;
        if (dino.activeInEncounter || dino.state == DinoBehaviorState::Dying) continue;
        if (dino.targetIndex >= kM1MaxTargets) continue;

        TargetComponent& target = world.target(dino.targetIndex);
        dino.waveId = waveId;
        dino.laneRole = (uint8_t)activated;
        dino.spawnGap = wave.spawnGap + (float)activated * 0.6f;
        dino.holdDuration = wave.holdSeconds;
        dino.attackDelay = wave.attackStaggerSeconds * (float)activated;
        dino.retreatDuration = 1.2f;
        dino.retreatGap = std::max(7.f, dino.spawnGap);
        dino.health = dino.maxHealth;
        dino.hitFlashTime = 0.f;

        target.active = true;
        target.moving = true;
        target.railDistance = std::max(0.f, camera.distance - dino.spawnGap);
        target.baseLateralOffset = wave.lanes[activated];
        target.lateralOffset = wave.lanes[activated];
        clear_target_hit(target);

        enter_approach(world, id, dino);
        ++activated;
    }
    return activated;
}

static void consume_raptor_wave_events(World& world) {
    const std::vector<ChartEvent>& events = world.chart().events;
    size_t index = world.next_chart_event_index();
    float distance = world.rail_camera().distance;
    while (index < events.size() && events[index].distance <= distance) {
        const ChartEvent& event = events[index];
        if (event.type == "raptor_wave" && event.raptorWave.valid) {
            activate_raptor_wave(world, event.raptorWave, (uint32_t)index + 1u);
        }
        ++index;
    }
    world.set_next_chart_event_index(index);
}

void DinoBehaviorSystem_update(World& world, float gameDt) {
    if (gameDt == 0.f) return;
    consume_raptor_wave_events(world);

    uint32_t count = world.entity_count();
    for (EntityID id = 0; id < count; ++id) {
        if (!world.has_component<DinoBehaviorComponent>(id)) continue;
        DinoBehaviorComponent& dino = world.get_component<DinoBehaviorComponent>(id);
        if (!dino.active) continue;
        // Boss arrival: the act finale joins once the jeep has covered the
        // authored distance — until then the boss sits dormant, letting the
        // raptor waves carry the early act. One-way: the wrap-looping test
        // rail can't re-trigger it, and play-again resets via
        // reset_m1_scene.
        if (dino.isBoss && !dino.activeInEncounter
            && dino.state == DinoBehaviorState::Dormant
            && world.rail_camera().distance >= dino.bossArrivalDistance) {
            if (dino.targetIndex < kM1MaxTargets) {
                TargetComponent& target = world.target(dino.targetIndex);
                target.railDistance = std::max(0.f, world.rail_camera().distance - 9.f);
            }
            enter_approach(world, id, dino);
        }
        if (!dino.activeInEncounter && dino.state != DinoBehaviorState::Dormant) {
            dino.state = DinoBehaviorState::Dormant;
        }
        if (!dino.activeInEncounter) continue;

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
            // Weak-point hits (the head region) deal double damage — aim
            // skill shortens every fight, and it's what makes the boss's
            // health pool feel like a puzzle instead of a grind.
            dino.health -= shotWasWeakPoint ? 2 : 1;
            dino.hitFlashTime = 0.2f;
            if (dino.isBoss) {
                // Escalation phases at 1/3 and 2/3 damage taken: shorter
                // holds and a quicker chase each phase. One-way per run.
                float taken = 1.f - (float)std::max(0, dino.health) / (float)dino.maxHealth;
                uint8_t phase = taken >= (2.f / 3.f) ? 2 : (taken >= (1.f / 3.f) ? 1 : 0);
                if (phase > dino.ragePhase) {
                    for (uint8_t step = dino.ragePhase; step < phase; ++step) {
                        dino.holdDuration *= 0.6f;
                        dino.chaseSpeed *= 1.2f;
                    }
                    dino.ragePhase = phase;
                    // A stat change alone reads as "the boss quietly got
                    // harder" — a shake makes the escalation an actual
                    // moment the player feels, not just a hidden number.
                    ScreenShakeSystem_trigger(world, 0.12f * (float)phase);
                }
            }
            if (dino.health <= 0) {
                emit_hit_score(world, shotPlayer, dino.species, shotWasWeakPoint,
                               world.target(dino.targetIndex));
                dino.state = DinoBehaviorState::Dying;
                dino.stateTime = 0.f;
                if (dino.isBoss) {
                    // The kill lands harder than a phase escalation — this
                    // is the fight's one moment, not a repeatable beat.
                    ScreenShakeSystem_trigger(world, 0.32f);
                }
                // Force: death must cut through whatever is playing,
                // including a mid-flight Attack.
                AnimationSystem_force_clip(world, id, CharacterClipSlot::Death);
                continue;
            }
        }

        switch (dino.state) {
            case DinoBehaviorState::Dormant:
                break;

            case DinoBehaviorState::Approach: {
                if (wasShot) {
                    emit_hit_score(world, shotPlayer, dino.species, shotWasWeakPoint,
                               world.target(dino.targetIndex));
                }
                if (dino.targetIndex < kM1MaxTargets) {
                    TargetComponent& target = world.target(dino.targetIndex);
                    float gap = std::max(0.f, world.rail_camera().distance - target.railDistance);
                    if (gap > dino.attackRange && dino.chaseSpeed > 0.f) {
                        target.railDistance += std::min(dino.chaseSpeed * gameDt,
                                                        gap - dino.attackRange);
                    }
                    gap = std::max(0.f, world.rail_camera().distance - target.railDistance);
                    if (gap <= dino.attackRange) {
                        target.railDistance += world.rail_camera().speed * gameDt;
                        enter_hold(world, id, dino);
                        break;
                    }
                }
                AnimationSystem_request_clip(world, id, CharacterClipSlot::Run);
                break;
            }

            case DinoBehaviorState::Hold: {
                if (wasShot) {
                    emit_hit_score(world, shotPlayer, dino.species, shotWasWeakPoint,
                               world.target(dino.targetIndex));
                }
                if (dino.targetIndex < kM1MaxTargets) {
                    TargetComponent& target = world.target(dino.targetIndex);
                    target.railDistance += world.rail_camera().speed * gameDt;
                }
                if (dino.stateTime >= dino.holdDuration + dino.attackDelay) {
                    enter_attack(world, id, dino);
                    break;
                }
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
                    int missedPlayer = -1;
                    if (dino.targetIndex < kM1MaxTargets) {
                        missedPlayer = nearest_damage_target_player(world, world.target(dino.targetIndex));
                    }
                    world.events().push_dino_score((uint8_t)missedPlayer,
                                                   DinoScoreEvent::InterruptFail,
                                                   dino.species);
                    enter_retreat(world, id, dino);
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
                                                   dino.species,
                                                   world.target(dino.targetIndex).screenX,
                                                   world.target(dino.targetIndex).screenY);
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
                    emit_hit_score(world, shotPlayer, dino.species, shotWasWeakPoint,
                               world.target(dino.targetIndex));
                }

                if (anim->clipDone && anim->currentClip == CharacterClipSlot::Attack) {
                    dino.lastOutcome = DinoInterruptOutcome::Failed;
                    dino.outcomeThisCycle = true;
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
                    enter_retreat(world, id, dino);
                    break;
                }
                break;
            }

            case DinoBehaviorState::Interrupted:
                if ((anim && anim->clipDone && anim->currentClip == CharacterClipSlot::Jump)
                    || dino.stateTime >= dino.jumpReactionDuration) {
                    enter_retreat(world, id, dino);
                }
                break;

            case DinoBehaviorState::Retreat: {
                if (dino.targetIndex < kM1MaxTargets) {
                    TargetComponent& target = world.target(dino.targetIndex);
                    target.railDistance = std::max(0.f,
                                                   target.railDistance - dino.chaseSpeed * 1.25f * gameDt);
                    float gap = world.rail_camera().distance - target.railDistance;
                    if (gap >= dino.retreatGap || dino.stateTime >= dino.retreatDuration) {
                        if (dino.isBoss) {
                            enter_approach(world, id, dino);
                        } else {
                            enter_dormant(world, id, dino);
                        }
                    }
                }
                break;
            }

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
                        if (dino.isBoss) {
                            complete_boss_death(world, dino);
                        } else {
                            respawn(world, id, dino);
                        }
                    }
                }
                break;
            }
        }
    }
}
