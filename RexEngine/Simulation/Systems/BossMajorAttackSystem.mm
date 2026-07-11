#include "BossMajorAttackSystem.h"
#include <algorithm>

// Damage multiplier indexed by miss count (1..4), relative to the boss's own
// attackDamage — a flawless clear (0 misses) is handled separately as
// Perfect (0 damage), so index 0 here corresponds to 1 miss. Roughly in line
// with a normal unopposed attack (1.0x) at 3 misses, meaningfully worse at a
// total whiff (1.5x) — appropriate for the fight's headline moment — and
// meaningfully better than a normal attack for a near-perfect 1-miss clear.
static const float kMissDamageMultiplier[4] = {0.5f, 0.75f, 1.0f, 1.5f};

void BossMajorAttackSystem_update(World& world, float gameDt) {
    BossMajorAttackState& attack = world.major_attack_mutable();
    if (!attack.active) return;

    if (!attack.resolved) {
        attack.timeRemaining = std::max(0.f, attack.timeRemaining - gameDt);
        bool perfect = attack.hitCount >= kBossMajorAttackPointCount;
        bool timedOut = attack.timeRemaining <= 0.f;
        if (perfect || timedOut) {
            attack.resolved = true;
            attack.resultHoldRemaining = 1.2f;

            if (perfect) {
                for (int p = 0; p < kRexMaxPlayers; ++p) {
                    if (!world.reticle(p).active || world.player_health(p).sittingOut) continue;
                    world.events().push_dino_score((uint8_t)p, DinoScoreEvent::MajorAttackPerfect,
                                                   attack.species);
                }
            } else {
                int misses = kBossMajorAttackPointCount - attack.hitCount;
                int missIndex = std::clamp(misses - 1, 0, 3);
                float damage = (float)world.get_component<DinoBehaviorComponent>(attack.bossEntity).attackDamage
                              * kMissDamageMultiplier[missIndex];
                for (int p = 0; p < kRexMaxPlayers; ++p) {
                    if (!world.reticle(p).active || world.player_health(p).sittingOut) continue;
                    world.damage_player(p, (int)damage);
                }
            }
        }
        return;
    }

    attack.resultHoldRemaining = std::max(0.f, attack.resultHoldRemaining - gameDt);
    if (attack.resultHoldRemaining <= 0.f) {
        attack.active = false;
    }
}
