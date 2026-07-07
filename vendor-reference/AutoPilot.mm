#include "AutoPilot.h"
#include "Simulation/World.h"
#include <math.h>

// Stop and punch inside CombatSystem's 130-unit attack range. Approaching
// head-on also sets FacingComponent toward the target, so the ±70° punch arc
// check passes once we stop.
static constexpr float kEngageDist = 100.0f;
static constexpr int   kStuckSampleFrames = 30; // ~0.5s at the fixed 60Hz scenario driver
static constexpr int   kUnstuckFrames     = 24; // ~0.4s
static float s_lastX[4] = {};
static float s_lastY[4] = {};
static int   s_sampleFrames[4] = {};
static int   s_unstuckFrames[4] = {};
static int   s_chargeFrames[4] = {};
static int   s_chargeCooldown[4] = {};
static bool  s_hasSample[4] = {};
static bool  s_dodgeEnabled = true;

static void add_hazard_avoidance(World& world, const PositionComponent& myPos,
                                 float* moveX, float* moveY) {
    float len = sqrtf((*moveX) * (*moveX) + (*moveY) * (*moveY));
    float nextX = myPos.x + (len > 0.001f ? (*moveX / len) * 34.f : 0.f);
    float nextY = myPos.y + (len > 0.001f ? (*moveY / len) * 34.f : 0.f);
    bool found = false;
    float bestD2 = 0.f;
    float awayX = 0.f;
    float awayY = 0.f;

    for (EntityID id = 0; id < world.entity_count(); ++id) {
        float cx = 0.f, cy = 0.f, radius = 0.f;
        if (world.hazards().present(id)) {
            if (!world.has_component<PositionComponent>(id)) continue;
            const PositionComponent& p = world.get_component<PositionComponent>(id);
            const HazardComponent& hz = world.get_component<HazardComponent>(id);
            cx = p.x; cy = p.y; radius = hz.radius + 30.f;
        } else if (world.lava_lobs().present(id)) {
            const LavaLobComponent& lob = world.get_component<LavaLobComponent>(id);
            cx = lob.destX; cy = lob.destY; radius = lob.poolRadius + 30.f;
        } else {
            continue;
        }
        float ndx = nextX - cx, ndy = nextY - cy;
        if (ndx * ndx + ndy * ndy > radius * radius) continue;
        float dx = myPos.x - cx, dy = myPos.y - cy;
        float d2 = dx * dx + dy * dy;
        if (!found || d2 < bestD2) {
            found = true;
            bestD2 = d2;
            float d = sqrtf(d2);
            awayX = d > 0.001f ? dx / d : 0.f;
            awayY = d > 0.001f ? dy / d : -1.f;
        }
    }
    if (!found) return;
    *moveX += awayX * 1.8f;
    *moveY += awayY * 1.8f;
    float outLen = sqrtf((*moveX) * (*moveX) + (*moveY) * (*moveY));
    if (outLen > 0.001f) {
        *moveX /= outLen;
        *moveY /= outLen;
    }
}

void AutoPilot_reset() {
    for (int i = 0; i < 4; ++i) {
        s_lastX[i] = 0.f;
        s_lastY[i] = 0.f;
        s_sampleFrames[i] = 0;
        s_unstuckFrames[i] = 0;
        s_chargeFrames[i] = 0;
        s_chargeCooldown[i] = 0;
        s_hasSample[i] = false;
    }
    s_dodgeEnabled = true;
}

void AutoPilot_set_dodge_enabled(bool enabled) {
    s_dodgeEnabled = enabled;
}

InputState AutoPilot_input(World& world, int playerIndex) {
    InputState in = {};

    // Find this player's entity.
    EntityID me = kInvalidEntity;
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.player_tags().present(id)) continue;
        if (world.get_component<PlayerTagComponent>(id).playerIndex == playerIndex) {
            me = id;
            break;
        }
    }
    if (me == kInvalidEntity || !world.has_component<PositionComponent>(me)) return in;
    if (world.has_component<DownedComponent>(me)) return in;
    if (world.has_component<AnimationComponent>(me) &&
        world.get_component<AnimationComponent>(me).dying) return in;

    const PositionComponent& myPos = world.get_component<PositionComponent>(me);

    if (world.has_component<SpecialMeterComponent>(me) &&
        world.get_component<SpecialMeterComponent>(me).charge >= 1.f) {
        int nearby = 0;
        for (EntityID id = 0; id < world.entity_count(); ++id) {
            if (!world.has_component<FactionComponent>(id)) continue;
            if (world.get_component<FactionComponent>(id).type != FactionComponent::Enemy) continue;
            if (!world.has_component<PositionComponent>(id)) continue;
            if (world.has_component<AnimationComponent>(id) &&
                world.get_component<AnimationComponent>(id).dying) continue;
            const PositionComponent& p = world.get_component<PositionComponent>(id);
            float dx = p.x - myPos.x, dy = p.y - myPos.y;
            if (dx * dx + dy * dy <= 220.f * 220.f)
                ++nearby;
        }
        if (nearby >= 2)
            in.special = true;
    }

    // Nearest living enemy.
    bool  found  = false;
    float bestD2 = 0.f, bdx = 0.f, bdy = 0.f;
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.has_component<FactionComponent>(id)) continue;
        if (world.get_component<FactionComponent>(id).type != FactionComponent::Enemy) continue;
        if (!world.has_component<PositionComponent>(id)) continue;
        if (world.has_component<AnimationComponent>(id) &&
            world.get_component<AnimationComponent>(id).dying) continue;

        const PositionComponent& p = world.get_component<PositionComponent>(id);
        float dx = p.x - myPos.x, dy = p.y - myPos.y;
        float d2 = dx * dx + dy * dy;
        if (!found || d2 < bestD2) {
            bestD2 = d2; bdx = dx; bdy = dy; found = true;
        }
    }
    EntityID downedMate = kInvalidEntity;
    float downedD2 = 0.f, ddx = 0.f, ddy = 0.f;
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (id == me) continue;
        if (!world.player_tags().present(id)) continue;
        if (!world.has_component<DownedComponent>(id)) continue;
        if (!world.has_component<PositionComponent>(id)) continue;
        const PositionComponent& p = world.get_component<PositionComponent>(id);
        float dx = p.x - myPos.x, dy = p.y - myPos.y;
        float d2 = dx * dx + dy * dy;
        if (downedMate == kInvalidEntity || d2 < downedD2) {
            downedMate = id; downedD2 = d2; ddx = dx; ddy = dy;
        }
    }

    if (downedMate != kInvalidEntity && (!found || bestD2 > 150.f * 150.f)) {
        float d = sqrtf(downedD2);
        in.moveX = (d > 0.001f) ? ddx / d : 0.f;
        in.moveY = (d > 0.001f) ? ddy / d : 0.f;
        return in;
    }

    if (!found) {
        EntityID exitID = kInvalidEntity;
        float exitD2 = 0.f, edx = 0.f, edy = 0.f;
        for (EntityID id = 0; id < world.entity_count(); ++id) {
            if (!world.exits().present(id)) continue;
            if (!world.has_component<PositionComponent>(id)) continue;
            const ExitComponent& exit = world.get_component<ExitComponent>(id);
            const PositionComponent& p = world.get_component<PositionComponent>(id);
            float dx = p.x - myPos.x, dy = p.y - myPos.y;
            float d2 = dx * dx + dy * dy;
            bool preferCalm = exitID == kInvalidEntity ||
                              (world.get_component<ExitComponent>(exitID).cursed && !exit.cursed);
            bool sameKindCloser = exitID != kInvalidEntity &&
                                  world.get_component<ExitComponent>(exitID).cursed == exit.cursed &&
                                  d2 < exitD2;
            if (preferCalm || sameKindCloser) {
                exitID = id; exitD2 = d2; edx = dx; edy = dy;
            }
        }
        if (exitID != kInvalidEntity) {
            float d = sqrtf(exitD2);
            in.moveX = (d > 0.001f) ? edx / d : 0.f;
            in.moveY = (d > 0.001f) ? edy / d : 0.f;
        }
        return in;
    }

    float dist = sqrtf(bestD2);

    // Defense: dodge deliberate incoming threats while continuing to trade
    // ordinary melee pressure. Hold the dash only briefly (one short i-frame
    // roll), then release — a competent player crosses the threat and resumes
    // attacking rather than chaining both charges into a long roll.
    if (s_dodgeEnabled && world.has_component<DodgeComponent>(me) &&
        world.get_component<DodgeComponent>(me).elapsed < 0.35f)
        in.dodge = true;
    bool meCanDodge = world.has_component<AnimationComponent>(me) &&
                      (world.get_component<AnimationComponent>(me).currentClip == AnimClipID::Idle ||
                       world.get_component<AnimationComponent>(me).currentClip == AnimClipID::Walk) &&
                      world.has_component<DodgeChargesComponent>(me) &&
                      world.get_component<DodgeChargesComponent>(me).charges > 0;
    if (s_dodgeEnabled && meCanDodge) {
        for (EntityID id = 0; id < world.entity_count(); ++id) {
            if (!world.projectiles().present(id)) continue;
            if (!world.has_component<PositionComponent>(id)) continue;
            const PositionComponent& pp = world.get_component<PositionComponent>(id);
            const ProjectileComponent& proj = world.get_component<ProjectileComponent>(id);
            float dx = myPos.x - pp.x;
            float dy = myPos.y - pp.y;
            float d2 = dx * dx + dy * dy;
            if (d2 > 160.f * 160.f || d2 <= 0.001f) continue;
            float speed = sqrtf(proj.vx * proj.vx + proj.vy * proj.vy);
            if (speed <= 0.001f) continue;
            float distToPath = fabsf(dx * proj.vy - dy * proj.vx) / speed;
            float closing = dx * proj.vx + dy * proj.vy;
            if (closing > 0.f && distToPath <= 55.f) {
                float side = (dx * proj.vy - dy * proj.vx) >= 0.f ? 1.f : -1.f;
                in.moveX = (-proj.vy / speed) * side;
                in.moveY = ( proj.vx / speed) * side;
                in.dodge = true;
                return in;
            }
        }
        for (EntityID id = 0; id < world.entity_count(); ++id) {
            if (!world.leapers().present(id)) continue;
            if (!world.has_component<PositionComponent>(id)) continue;
            if (world.has_component<AnimationComponent>(id) &&
                world.get_component<AnimationComponent>(id).dying) continue;
            const LeaperComponent& leap = world.get_component<LeaperComponent>(id);
            if (leap.state != 1 && leap.state != 2) continue;
            float dx = myPos.x - leap.destX;
            float dy = myPos.y - leap.destY;
            if (dx * dx + dy * dy < 140.f * 140.f) {
                float d = sqrtf(dx * dx + dy * dy);
                in.moveX = d > 0.001f ? dx / d : 0.f;
                in.moveY = d > 0.001f ? dy / d : -1.f;
                in.dodge = true;
                return in;
            }
        }
        for (EntityID id = 0; id < world.entity_count(); ++id) {
            if (!world.boss_tags().present(id)) continue;
            if (!world.has_component<PositionComponent>(id)) continue;
            if (world.has_component<AnimationComponent>(id) &&
                world.get_component<AnimationComponent>(id).dying) continue;

            bool threatening = world.has_component<AnimationComponent>(id) &&
                               world.get_component<AnimationComponent>(id).currentClip
                                   == AnimClipID::Attack;
            if (world.has_component<BossChargeComponent>(id)) {
                uint8_t st = world.get_component<BossChargeComponent>(id).state;
                threatening |= (st == BossChargeComponent::Telegraph ||
                                st == BossChargeComponent::Charge);
            }
            if (!threatening) continue;

            const auto& p = world.get_component<PositionComponent>(id);
            float dx = p.x - myPos.x, dy = p.y - myPos.y;
            if (dx * dx + dy * dy < 240.f * 240.f) {
                in.dodge = true;
                return in;
            }
        }
    }

    // Always steer toward the target — also while punching. Movement is what
    // updates FacingComponent, and a stale facing fails CombatSystem's ±70°
    // arc check forever (the bot once dead-locked whiffing at a rusher that
    // approached from a different direction than its previous kill).
    in.moveX = (dist > 0.001f) ? bdx / dist : 0.f;
    in.moveY = (dist > 0.001f) ? bdy / dist : 0.f;

    int slot = (playerIndex >= 0 && playerIndex < 4) ? playerIndex : 0;
    if (!s_hasSample[slot]) {
        s_lastX[slot] = myPos.x;
        s_lastY[slot] = myPos.y;
        s_sampleFrames[slot] = 0;
        s_unstuckFrames[slot] = 0;
        s_hasSample[slot] = true;
    }
    s_sampleFrames[slot] += 1;
    if (s_sampleFrames[slot] >= kStuckSampleFrames) {
        float sx = myPos.x - s_lastX[slot];
        float sy = myPos.y - s_lastY[slot];
        bool tryingToMove = (in.moveX * in.moveX + in.moveY * in.moveY) > 0.01f;
        if (tryingToMove && sx * sx + sy * sy <= 2.f * 2.f)
            s_unstuckFrames[slot] = kUnstuckFrames;
        else if (sx * sx + sy * sy > 120.f * 120.f)
            s_unstuckFrames[slot] = 0; // room reload or respawn
        s_lastX[slot] = myPos.x;
        s_lastY[slot] = myPos.y;
        s_sampleFrames[slot] = 0;
    }
    if (s_unstuckFrames[slot] > 0 &&
        (in.moveX * in.moveX + in.moveY * in.moveY) > 0.01f) {
        float px = -in.moveY;
        float py =  in.moveX;
        in.moveX = px;
        in.moveY = py;
        s_unstuckFrames[slot] -= 1;
    }

    if (s_dodgeEnabled)
        add_hazard_avoidance(world, myPos, &in.moveX, &in.moveY);

    if (s_chargeCooldown[slot] > 0) s_chargeCooldown[slot] -= 1;
    if (s_chargeFrames[slot] > 0) {
        in.moveX = 0.f;
        in.moveY = 0.f;
        s_chargeFrames[slot] -= 1;
        in.attack = s_chargeFrames[slot] > 0;
        if (!in.attack) s_chargeCooldown[slot] = 900;
        return in;
    }

    int enemiesInHeavy = 0;
    bool nearbyThreat = false;
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (world.hazards().present(id)) {
            if (!world.has_component<PositionComponent>(id)) continue;
            const PositionComponent& p = world.get_component<PositionComponent>(id);
            const HazardComponent& hz = world.get_component<HazardComponent>(id);
            float dx = p.x - myPos.x, dy = p.y - myPos.y;
            nearbyThreat |= dx * dx + dy * dy < (hz.radius + 50.f) * (hz.radius + 50.f);
            continue;
        }
        if (!world.has_component<FactionComponent>(id)) continue;
        if (world.get_component<FactionComponent>(id).type != FactionComponent::Enemy) continue;
        if (!world.has_component<PositionComponent>(id)) continue;
        if (world.has_component<AnimationComponent>(id) &&
            world.get_component<AnimationComponent>(id).dying) continue;
        const PositionComponent& p = world.get_component<PositionComponent>(id);
        float dx = p.x - myPos.x, dy = p.y - myPos.y;
        float d2 = dx * dx + dy * dy;
        if (d2 <= 150.f * 150.f) enemiesInHeavy += 1;
        bool attacking = world.has_component<AnimationComponent>(id) &&
                         world.get_component<AnimationComponent>(id).currentClip == AnimClipID::Attack;
        nearbyThreat |= attacking && d2 <= 135.f * 135.f;
    }
    bool canCharge = world.has_component<AnimationComponent>(me) &&
                     world.get_component<AnimationComponent>(me).currentClip == AnimClipID::Idle &&
                     s_chargeCooldown[slot] <= 0 &&
                     enemiesInHeavy >= 2 &&
                     !nearbyThreat &&
                     dist <= 145.f &&
                     world.rand_range(300) == 0;
    if (canCharge) {
        s_chargeFrames[slot] = 42;
        in.moveX = 0.f;
        in.moveY = 0.f;
        in.attack = true;
        return in;
    }

    if (dist <= kEngageDist) {
        // Hold attack through the first punch (which both starts the swing and
        // queues the Attack→Attack2 combo), but release during the finisher so
        // the clip can exit to Idle and the next swing can start.
        bool inFinisher = world.has_component<AnimationComponent>(me) &&
                          world.get_component<AnimationComponent>(me).currentClip == AnimClipID::Attack2;
        in.attack = !inFinisher;
    }
    return in;
}
