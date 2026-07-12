#include "BossMajorAttackSystem.h"
#include "Simulation/BossMajorAttackPoints.h"
#include "Simulation/Systems/AnimationSystem.h"
#include <algorithm>

// Damage multiplier indexed by miss count (1..4), relative to the boss's own
// attackDamage — a flawless clear (0 misses) is handled separately as
// Perfect (0 damage), so index 0 here corresponds to 1 miss. Roughly in line
// with a normal unopposed attack (1.0x) at 3 misses, meaningfully worse at a
// total whiff (1.5x), and meaningfully better for a near-perfect 1-miss clear.
static const float kMissDamageMultiplier[4] = {0.5f, 0.75f, 1.0f, 1.5f};

// Places the 4 authored body-box points into the boss's LIVE projected screen
// box (recomputed every tick by RailCameraSystem) and advances each point's
// closing-ring appearance on its staggered schedule. Because the box tracks
// the moving/animating dino, the points ride it for free — no separate 3D
// projection. A collapsed box (boss briefly off-screen) keeps the previous
// placement rather than snapping the points to screen center.
static void update_live_points(World& world, BossMajorAttackState& attack) {
    const BossMajorAttackPoint* table = BossMajorAttackPoints_for(attack.species);
    float bx = 0.5f, by = 0.5f, hw = 0.12f, hh = 0.16f;
    bool haveBox = false;
    uint32_t bossId = attack.bossEntity;
    if (bossId != UINT32_MAX && world.has_component<DinoBehaviorComponent>(bossId)) {
        const DinoBehaviorComponent& boss = world.get_component<DinoBehaviorComponent>(bossId);
        if (boss.targetIndex < kM1MaxTargets) {
            const TargetComponent& t = world.target(boss.targetIndex);
            if (t.screenHalfW > 0.f && t.screenHalfH > 0.f) {
                bx = t.screenX;
                by = t.screenY;
                // Floor the box so the four points stay spread and comfortably
                // hittable even when the boss is projected small.
                hw = std::max(t.screenHalfW, 0.10f);
                hh = std::max(t.screenHalfH, 0.14f);
                haveBox = true;
            }
        }
    }
    for (int i = 0; i < kBossMajorAttackPointCount; ++i) {
        BossMajorAttackPointState& p = attack.points[i];
        p.hitRadius = table[i].hitRadius;
        if (haveBox || p.appear <= 0.f) {
            BossMajorAttackPoint_place(table[i], bx, by, hw, hh, &p.screenX, &p.screenY);
        }
        float spawnAt = (float)i * kMajorAttackPointStagger;
        if (attack.liveElapsed >= spawnAt) {
            float since = attack.liveElapsed - spawnAt;
            // Clamp the low end above 0 so "spawned" (shootable) reads as
            // appear > 0 even on the very first frame a point shows.
            p.appear = std::clamp(since / kMajorAttackPointAppear, 0.001f, 1.f);
        }
    }
}

static void resolve(World& world, BossMajorAttackState& attack, bool perfect) {
    attack.phase = MajorAttackPhase::Result;
    attack.resolved = true;
    attack.wasPerfect = perfect;
    attack.resultHoldRemaining = kMajorAttackResultHold;

    if (perfect) {
        // Perfect is a bonus, not a shot: it doesn't touch accuracy/streak
        // (each of the 4 points already did via MajorAttackPointHit).
        for (int p = 0; p < kRexMaxPlayers; ++p) {
            if (!world.reticle(p).active || world.player_health(p).sittingOut) continue;
            world.events().push_dino_score((uint8_t)p, DinoScoreEvent::MajorAttackPerfect,
                                           attack.species);
        }
        return;
    }
    // Failure: the boss retaliates. Damage scales with how many points were
    // MISSED, splashed to every active player (the QTE is shared, unlike the
    // single-target ambient-attack path).
    int misses = kBossMajorAttackPointCount - attack.hitCount;
    int missIndex = std::clamp(misses - 1, 0, 3);
    float damage = kMissDamageMultiplier[missIndex];
    if (attack.bossEntity != UINT32_MAX
        && world.has_component<DinoBehaviorComponent>(attack.bossEntity)) {
        damage *= (float)world.get_component<DinoBehaviorComponent>(attack.bossEntity).attackDamage;
    }
    for (int p = 0; p < kRexMaxPlayers; ++p) {
        if (!world.reticle(p).active || world.player_health(p).sittingOut) continue;
        world.damage_player(p, (int)damage);
    }
}

static void finish(World& world, BossMajorAttackState& attack) {
    world.note_major_attack_resolved();
    bool isFinal = attack.isFinal;
    uint32_t bossId = attack.bossEntity;
    // End the QTE: phase back to Inactive so World::tick restores full-speed
    // timing on the next tick.
    attack.phase = MajorAttackPhase::Inactive;

    if (isFinal && bossId != UINT32_MAX && world.has_component<DinoBehaviorComponent>(bossId)) {
        // Boss defeated: it flees rather than dies. Send it into Retreat so it
        // visibly runs off, and open the flee window that completes the level.
        DinoBehaviorComponent& boss = world.get_component<DinoBehaviorComponent>(bossId);
        boss.state = DinoBehaviorState::Retreat;
        boss.stateTime = 0.f;
        AnimationSystem_force_clip(world, bossId, CharacterClipSlot::Run);
        world.begin_boss_flee();
    }
}

void BossMajorAttackSystem_update(World& world, float gameDt) {
    BossMajorAttackState& attack = world.major_attack_mutable();
    if (!attack.active()) return;

    switch (attack.phase) {
        case MajorAttackPhase::Preview: {
            // Telegraph only — no shooting, no countdown yet. Points reveal
            // one-by-one in the renderer off previewElapsed.
            attack.previewElapsed += gameDt;
            if (attack.previewElapsed >= attack.previewDuration) {
                attack.phase = MajorAttackPhase::Live;
                attack.timeRemaining = attack.countdownDuration;
                attack.liveElapsed = 0.f;
                update_live_points(world, attack); // seed positions before the first hit-test
            }
            return;
        }
        case MajorAttackPhase::Live: {
            attack.liveElapsed += gameDt;
            update_live_points(world, attack);
            attack.timeRemaining = std::max(0.f, attack.timeRemaining - gameDt);
            bool perfect = attack.hitCount >= kBossMajorAttackPointCount;
            bool timedOut = attack.timeRemaining <= 0.f;
            if (perfect || timedOut) {
                resolve(world, attack, perfect);
            }
            return;
        }
        case MajorAttackPhase::Result: {
            attack.resultHoldRemaining = std::max(0.f, attack.resultHoldRemaining - gameDt);
            if (attack.resultHoldRemaining <= 0.f) {
                finish(world, attack);
            }
            return;
        }
        case MajorAttackPhase::Inactive:
            return;
    }
}
