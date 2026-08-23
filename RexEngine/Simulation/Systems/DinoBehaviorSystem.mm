#include "DinoBehaviorSystem.h"
#include "Simulation/Systems/AnimationSystem.h"
#include "Simulation/Systems/ScreenShakeSystem.h"
#include <algorithm>
#include <math.h>
#include <stdio.h>

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
        target.verticalOffset = 0.f;
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

// A dino holding in range plays a run cycle while it PACES to keep up with a
// moving jeep, but a STANDING idle once the jeep has stopped (the arena
// holdout) — otherwise it looks like it's running in place a few feet away.
static CharacterClipSlot hold_clip(World& world) {
    return world.rail_camera().speed <= 0.001f ? CharacterClipSlot::Idle
                                               : CharacterClipSlot::Run;
}

static void enter_hold(World& world, EntityID id, DinoBehaviorComponent& dino) {
    dino.state = DinoBehaviorState::Hold;
    dino.stateTime = 0.f;
    AnimationSystem_request_clip(world, id, hold_clip(world));
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

static void enter_put_down(World& world, EntityID id, DinoBehaviorComponent& dino) {
    dino.health = 0;
    dino.state = DinoBehaviorState::PutDown;
    dino.stateTime = 0.f;
    if (world.has_component<AnimationComponent>(id)) {
        world.get_component<AnimationComponent>(id).deathFade = 1.f;
    }
    AnimationSystem_force_clip(world, id, CharacterClipSlot::Jump);
    if (dino.targetIndex < kM1MaxTargets) {
        TargetComponent& target = world.target(dino.targetIndex);
        world.particles().spawn_burst(target.worldX, target.worldY, target.worldZ,
                                      14, 1.6f, 0.09f,
                                      0.72f, 0.62f, 0.42f,
                                      world.rand_u32());
    }
}

static void enter_departing(World& world, EntityID id, DinoBehaviorComponent& dino) {
    dino.state = DinoBehaviorState::Departing;
    dino.stateTime = 0.f;
    AnimationSystem_force_clip(world, id, CharacterClipSlot::Run);
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

static int configure_raptor_health(World& world, EntityID id,
                                   DinoBehaviorComponent& dino,
                                   const char *label) {
    float closingRate = std::max(0.1f, dino.chaseSpeed - world.rail_camera().speed);
    float approachTime = std::max(0.f, dino.spawnGap - dino.attackRange) / closingRate;
    float holdTime = dino.holdDuration + dino.attackDelay;
    float attackDuration = AnimationSystem_clip_duration(world, id, CharacterClipSlot::Attack);
    float tellTime = dino.interruptEndNormalized * attackDuration
                   / kAttackClipSpeedMultiplier;
    float window = approachTime + holdTime + tellTime;
    if (window < kMinFairWindowSeconds) {
        fprintf(stderr,
                "DinoBehaviorSystem: unfair raptor wave '%s' window %.3fs; clamping to %.3fs\n",
                (label && label[0]) ? label : "<unlabeled>", window, kMinFairWindowSeconds);
        window = kMinFairWindowSeconds;
    }
    dino.shootingWindowSeconds = window;
    int players = std::max(1, world.active_player_count());
    int health = std::clamp((int)lroundf(kHealthPerWindowSecond * window * (float)players),
                            1, kMaxDinoHealth);
    dino.maxHealth = health;
    dino.health = health;
    return health;
}

static void configure_raptor_animation(World& world, EntityID id) {
    if (!world.has_component<AnimationComponent>(id)) return;
    AnimationComponent& anim = world.get_component<AnimationComponent>(id);
    anim.deathFade = 1.f;
    anim.rateScale = 0.88f + world.rand_float01() * 0.24f;
    AnimationSystem_force_clip(world, id, CharacterClipSlot::Run);
    float runDuration = AnimationSystem_clip_duration(world, id, CharacterClipSlot::Run);
    anim.clipTime = world.rand_float01() * std::max(0.f, runDuration);
}

struct RaptorArchetypePreset {
    float minGap;
    float maxGap;
    float verticalOffset;
    float holdScale;
};

static constexpr RaptorArchetypePreset kRaptorArchetypes[] = {
    {8.0f, 11.5f,  0.00f, 1.00f}, // chase
    {2.8f,  4.0f,  0.00f, 0.45f}, // close_ambush
    {4.0f,  6.0f,  2.50f, 0.70f}, // canopy_drop
    {5.0f,  8.0f, -0.25f, 1.10f}, // low_crawl
};

static const RaptorArchetypePreset& preset_for(RaptorArchetype archetype) {
    return kRaptorArchetypes[(int)archetype];
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
        if (dino.activeInEncounter || dino.state == DinoBehaviorState::PutDown) continue;
        if (dino.targetIndex >= kM1MaxTargets) continue;

        TargetComponent& target = world.target(dino.targetIndex);
        RaptorArchetype archetype = wave.entries[activated].archetype;
        const RaptorArchetypePreset& preset = preset_for(archetype);
        dino.waveId = waveId;
        dino.laneRole = (uint8_t)activated;
        dino.archetype = archetype;
        dino.spawnGap = wave.usesEntries
                      ? preset.minGap + world.rand_float01() * (preset.maxGap - preset.minGap)
                      : wave.spawnGap + (float)activated * 0.6f;
        dino.holdDuration = wave.holdSeconds * (wave.usesEntries ? preset.holdScale : 1.f);
        dino.attackDelay = wave.attackStaggerSeconds * (float)activated;
        dino.retreatDuration = 1.2f;
        dino.retreatGap = std::max(7.f, dino.spawnGap);
        dino.hitFlashTime = 0.f;
        configure_raptor_health(world, id, dino, wave.label.c_str());

        target.active = true;
        target.moving = true;
        target.railDistance = std::max(0.f, camera.distance - dino.spawnGap);
        target.baseLateralOffset = wave.entries[activated].lane;
        target.lateralOffset = wave.entries[activated].lane;
        target.verticalOffset = wave.usesEntries ? preset.verticalOffset : 0.f;
        dino.canopyLanded = archetype != RaptorArchetype::CanopyDrop;
        clear_target_hit(target);

        enter_approach(world, id, dino);
        configure_raptor_animation(world, id);
        if (archetype == RaptorArchetype::CanopyDrop) {
            AnimationSystem_force_clip(world, id, CharacterClipSlot::Jump);
        }
        ++activated;
    }
    return activated;
}

// True if no major_attack event sits at a LATER chart index than `index` — i.e.
// the QTE about to fire is the fight's last, after which the boss flees.
static bool is_last_major_attack(const std::vector<ChartEvent>& events, size_t index) {
    for (size_t i = index + 1; i < events.size(); ++i) {
        if (events[i].type == "major_attack") return false;
    }
    return true;
}

static void trigger_major_attack(World& world, bool isFinal) {
    uint32_t bossId = world.boss_entity();
    if (bossId == kInvalidEntity || !world.has_component<DinoBehaviorComponent>(bossId)) return;
    DinoBehaviorComponent& boss = world.get_component<DinoBehaviorComponent>(bossId);
    // The boss must actually be in the fight — a QTE authored before the boss
    // has arrived is silently dropped (author error) rather than popping over
    // an empty road.
    if (!boss.isBoss || !boss.activeInEncounter) return;
    // Ambient escalation each QTE (replaces the old damage-taken thresholds,
    // which can't fire now that the boss takes no fire damage): shorter holds,
    // a quicker chase, and a redder tint (renderer reads ragePhase).
    if (boss.ragePhase < 2) {
        ++boss.ragePhase;
        boss.holdDuration *= 0.7f;
        boss.chaseSpeed *= 1.15f;
    }
    ScreenShakeSystem_trigger(world, 0.12f * (float)(boss.ragePhase + 1));
    world.begin_boss_major_attack(bossId, boss.species, /*showPortrait=*/true, isFinal);
}

// Any raptor still in the fight (including one mid-death, which is still on
// screen). A boss major attack must not pop while one of these is present.
static bool any_active_raptor(World& world) {
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.has_component<DinoBehaviorComponent>(id)) continue;
        const DinoBehaviorComponent& dino = world.get_component<DinoBehaviorComponent>(id);
        if (dino.isBoss || dino.species != DinoSpecies::Velociraptor) continue;
        if (dino.activeInEncounter) return true;
    }
    return false;
}

static void consume_chart_events(World& world) {
    const std::vector<ChartEvent>& events = world.chart().events;
    size_t index = world.next_chart_event_index();
    float distance = world.rail_camera().distance;
    while (index < events.size() && events[index].distance <= distance) {
        const ChartEvent& event = events[index];
        if (event.type == "major_attack") {
            // The T-Rex QTE must never overlap a raptor wave — two threats at
            // once is confusing to read. DEFER it (leave the event index parked
            // here, don't advance past it) until the field is clear; it fires
            // the instant the last raptor dies. Because the index stays put,
            // any later wave authored behind this QTE also waits, which yields
            // the intended wave / QTE / wave / QTE cadence instead of an
            // overlap.
            if (any_active_raptor(world)) break;
            trigger_major_attack(world, is_last_major_attack(events, index));
        } else if (event.type == "raptor_wave" && event.raptorWave.valid) {
            activate_raptor_wave(world, event.raptorWave, (uint32_t)index + 1u);
        }
        ++index;
    }
    world.set_next_chart_event_index(index);
}

void DinoBehaviorSystem_update(World& world, float gameDt) {
    if (gameDt == 0.f) return;
    consume_chart_events(world);

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
        bool interruptPutDown = false;
        if (wasShot && !dino.isBoss && anim
            && (dino.state == DinoBehaviorState::Tell || dino.state == DinoBehaviorState::Attack)) {
            float progress = attack_progress(world, id, *anim);
            interruptPutDown = progress >= dino.interruptStartNormalized
                            && progress <= dino.interruptEndNormalized;
            if (interruptPutDown) {
                dino.lastOutcome = DinoInterruptOutcome::Succeeded;
                dino.outcomeThisCycle = true;
                world.events().push_dino_score(shotPlayer,
                                               DinoScoreEvent::InterruptSuccess,
                                               dino.species,
                                               world.target(dino.targetIndex).screenX,
                                               world.target(dino.targetIndex).screenY);
                enter_put_down(world, id, dino);
                continue;
            }
        }
        if (wasShot && dino.state != DinoBehaviorState::PutDown
                    && dino.state != DinoBehaviorState::Departing) {
            if (dino.isBoss) {
                // Bosses are IMMUNE to normal fire (Jurassic Park model): a
                // hit still flashes and scores/streaks (the per-state
                // emit_hit_score below), but never drains a health pool. The
                // only way to damage a boss is the chart-scripted major-attack
                // QTE, and it flees once every scripted QTE resolves — it never
                // dies here. See BossMajorAttackSystem / World::begin_boss_flee.
                dino.hitFlashTime = 0.2f;
            } else {
                // Weak-point hits (the head region) deal double damage — aim
                // skill shortens every raptor pass.
                dino.health -= shotWasWeakPoint ? 2 : 1;
                dino.hitFlashTime = 0.2f;
                if (dino.health <= 0) {
                    emit_hit_score(world, shotPlayer, dino.species, shotWasWeakPoint,
                                   world.target(dino.targetIndex));
                    enter_put_down(world, id, dino);
                    continue;
                }
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
                    if (dino.archetype == RaptorArchetype::CanopyDrop && !dino.canopyLanded) {
                        float t = std::clamp(dino.stateTime / 0.5f, 0.f, 1.f);
                        float easeOut = 1.f - (1.f - t) * (1.f - t);
                        target.verticalOffset = 2.5f * (1.f - easeOut);
                        if (t >= 1.f) {
                            dino.canopyLanded = true;
                            target.verticalOffset = 0.f;
                            AnimationSystem_force_clip(world, id, CharacterClipSlot::Run);
                        } else {
                            AnimationSystem_force_clip(world, id, CharacterClipSlot::Jump);
                        }
                    }
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
                if (dino.archetype != RaptorArchetype::CanopyDrop || dino.canopyLanded) {
                    AnimationSystem_request_clip(world, id, CharacterClipSlot::Run);
                }
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
                if (dino.stateTime >= dino.holdDuration + dino.attackDelay
                    && !dino.isBoss) {
                    // The boss NEVER melees (Jurassic Park model): it is immune
                    // to fire AND deals no contact damage. Its only attack is
                    // the chart-scripted slow-motion QTE, whose miss-count curve
                    // is the sole source of boss damage (see BossMajorAttackSystem).
                    // So the boss just looms at range in Hold; only raptors run
                    // the Tell/Attack melee cycle.
                    enter_attack(world, id, dino);
                    break;
                }
                AnimationSystem_request_clip(world, id, hold_clip(world));
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
                    if (missedPlayer >= 0) {
                        world.damage_player(missedPlayer, dino.attackDamage);
                    }
                    if (dino.isBoss || dino.arena) enter_retreat(world, id, dino);
                    else enter_departing(world, id, dino);
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

                if (wasShot) {
                    emit_hit_score(world, shotPlayer, dino.species, shotWasWeakPoint,
                               world.target(dino.targetIndex));
                }

                // The extra !major_attack_active() guard is defense in depth
                // against a boss's own Attack clip completing WHILE its major
                // attack QTE popup is up: the slow-motion scale (see
                // kMajorAttackSlowMoScale) is already sized so this can't
                // happen with any clip length seen in this project, but this
                // makes the "attack landed unopposed" branch structurally
                // unable to fire during the popup regardless of future
                // tuning or a faster future boss animation — a double-attack
                // (this branch's normal damage AND the QTE's own damage
                // curve both landing) would otherwise be possible.
                if (anim->clipDone && anim->currentClip == CharacterClipSlot::Attack
                    && !world.major_attack_active()) {
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
                    if (dino.isBoss || dino.arena) enter_retreat(world, id, dino);
                    else enter_departing(world, id, dino);
                    break;
                }
                break;
            }

            case DinoBehaviorState::Retreat: {
                if (dino.targetIndex < kM1MaxTargets) {
                    TargetComponent& target = world.target(dino.targetIndex);
                    target.railDistance = std::max(0.f,
                                                   target.railDistance - dino.chaseSpeed * 1.25f * gameDt);
                    float gap = world.rail_camera().distance - target.railDistance;
                    if (gap >= dino.retreatGap || dino.stateTime >= dino.retreatDuration) {
                        if (dino.isBoss || dino.arena) {
                            // Arena raptors (like the boss) keep coming — they
                            // re-approach instead of parking dormant, so the
                            // holdout ends only when the player KILLS them.
                            enter_approach(world, id, dino);
                        } else {
                            enter_dormant(world, id, dino);
                        }
                    }
                }
                break;
            }

            case DinoBehaviorState::PutDown: {
                if (!anim) {
                    enter_dormant(world, id, dino);
                    break;
                }
                anim->deathFade = std::max(0.f, 1.f - dino.stateTime / 0.4f);
                if (anim->deathFade <= 0.f) {
                    enter_dormant(world, id, dino);
                }
                break;
            }

            case DinoBehaviorState::Departing: {
                if (anim) anim->deathFade = std::max(0.f, 1.f - dino.stateTime / 0.9f);
                if (dino.targetIndex < kM1MaxTargets) {
                    TargetComponent& target = world.target(dino.targetIndex);
                    target.railDistance = std::max(0.f,
                                                   target.railDistance - dino.chaseSpeed * 1.25f * gameDt);
                    float gap = world.rail_camera().distance - target.railDistance;
                    if (gap >= dino.retreatGap || dino.stateTime >= 0.9f) {
                        enter_dormant(world, id, dino);
                    }
                }
                break;
            }
        }
    }
}

bool DinoBehaviorSystem_spawn_arena_raptor(World& world, uint32_t waveId,
                                           float laneOffset, float spawnGap,
                                           float holdSeconds, float attackDelay) {
    const RailCameraState& camera = world.rail_camera();
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.has_component<DinoBehaviorComponent>(id)) continue;
        DinoBehaviorComponent& dino = world.get_component<DinoBehaviorComponent>(id);
        if (dino.species != DinoSpecies::Velociraptor || dino.isBoss) continue;
        if (dino.activeInEncounter || dino.state == DinoBehaviorState::PutDown) continue;
        if (dino.targetIndex >= kM1MaxTargets) continue;

        TargetComponent& target = world.target(dino.targetIndex);
        dino.arena = true;
        dino.waveId = waveId;
        dino.holdDuration = holdSeconds;
        dino.attackDelay = attackDelay;
        // Arena raptors hold MUCH farther back than road pursuers, for two
        // reasons that both come from the jeep being stopped:
        //   1. Framing. The camera rides at ~0.3 world height, so a raptor
        //      parked 3.4 units away puts the lens at its chest and you read
        //      neck instead of animal. At ~6 units the whole silhouette sits
        //      in frame with room above it.
        //   2. Frustum. The clamp in RailCameraSystem widens with depth, so
        //      the spread lanes project as a readable left/center/right fan
        //      rather than being squeezed toward the edges.
        dino.attackRange = 6.0f;
        // Nothing is fleeing them here, so the road chase speed (~3.55 against
        // a jeep doing 1.2) becomes the FULL closing rate and they cross the
        // approach in well under two seconds — reading as "spawned in your
        // face" rather than "ran at you". Slow them to keep the approach
        // legible now that it's the only thing covering the distance.
        dino.chaseSpeed = 2.0f;
        dino.retreatDuration = 0.9f;
        dino.retreatGap = std::max(5.f, spawnGap - 2.f);
        dino.hitFlashTime = 0.f;
        dino.spawnGap = spawnGap;
        configure_raptor_health(world, id, dino, "arena");

        target.active = true;
        target.moving = true;
        target.railDistance = std::max(0.f, camera.distance - spawnGap);
        target.baseLateralOffset = laneOffset;
        target.lateralOffset = laneOffset;
        clear_target_hit(target);

        enter_approach(world, id, dino);
        configure_raptor_animation(world, id);
        return true;
    }
    return false;
}
