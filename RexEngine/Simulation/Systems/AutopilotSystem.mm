#include "AutopilotSystem.h"
#include "Simulation/World.h"
#include <algorithm>
#include <cmath>

namespace {

// Stick deflection per unit of screen-space error. High enough to close a
// half-screen gap in a few tenths of a second, low enough that the reticle
// eases into the box instead of ringing around it.
constexpr float kSteerGain = 26.f;

// A shot is taken once the reticle is this deep inside the target box —
// slightly inside the edge, so a shot is not spent on the frame the box is
// only grazed.
constexpr float kFireMargin = 0.7f;

// Edge-gated states (title, play-again, continue) need fire to be SEEN
// released. Hold for this many ticks, then release for this many.
constexpr int kPulseDown = 8;
constexpr int kPulseUp   = 14;

bool pulse_fire(AutopilotState& state) {
    state.pulsePhase = (state.pulsePhase + 1) % (kPulseDown + kPulseUp);
    return state.pulsePhase < kPulseDown;
}

// The dino driving a given target slot, or nullptr for a plain popup /
// moving target (which has no behavior component behind it).
const DinoBehaviorComponent* dino_for_target(const World& world, int targetIndex) {
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.has_component<DinoBehaviorComponent>(id)) continue;
        const DinoBehaviorComponent& dino = world.get_component<DinoBehaviorComponent>(id);
        if (dino.active && dino.targetIndex == (uint8_t)targetIndex) return &dino;
    }
    return nullptr;
}

// Front-most (largest railDistance) wins, because that is who the bullet
// actually hits: since 3e64496 one shot damages only the front-most target
// whose box contains the reticle. Aiming at anything behind that would fire
// into a shield.
int pick_target(const World& world) {
    int best = -1;
    bool bestInterrupting = false;
    float bestRail = 0.f;
    for (int i = 0; i < kM1MaxTargets; ++i) {
        const TargetComponent& target = world.target(i);
        if (!target.active) continue;
        const DinoBehaviorComponent* dino = dino_for_target(world, i);
        // The interrupt window is where this game's points are. Shooting a
        // dino mid-lunge denies the attack; shooting it at any other time is
        // just chip damage. A bot that ignored this would demo the game
        // badly AND soak-test the wrong path.
        bool interrupting = dino && dino->interruptWindowOpen;
        if (best < 0
            || (interrupting && !bestInterrupting)
            || (interrupting == bestInterrupting && target.railDistance > bestRail)) {
            best = i;
            bestInterrupting = interrupting;
            bestRail = target.railDistance;
        }
    }
    return best;
}

// The live QTE point to shoot next: nearest to the reticle among those that
// have appeared and are unclaimed.
int pick_major_attack_point(const BossMajorAttackState& attack, const ReticleComponent& reticle) {
    int best = -1;
    float bestDistSq = 0.f;
    for (int i = 0; i < kBossMajorAttackPointCount; ++i) {
        const BossMajorAttackPointState& point = attack.points[i];
        if (point.hit || point.appear <= 0.f) continue;
        float dx = point.screenX - reticle.x, dy = point.screenY - reticle.y;
        float distSq = dx * dx + dy * dy;
        if (best < 0 || distSq < bestDistSq) { best = i; bestDistSq = distSq; }
    }
    return best;
}

void steer(InputState& in, const ReticleComponent& reticle, float toX, float toY) {
    in.stickX = std::clamp((toX - reticle.x) * kSteerGain, -1.f, 1.f);
    in.stickY = std::clamp((toY - reticle.y) * kSteerGain, -1.f, 1.f);
}

} // namespace

InputState AutopilotSystem_input(const World& world, AutopilotState& state, int playerIndex) {
    InputState in{};
    ++state.tick;

    if (playerIndex < 0 || playerIndex >= kRexMaxPlayers) return in;

    // Grade screen: pulse to start another run, so a long capture or soak
    // loops instead of parking on the panel.
    if (world.level_complete()) {
        in.fire = pulse_fire(state);
        return in;
    }

    // Title: no stick (selection 0 is 1 PLAYER — the bot plays solo), pulse
    // fire until the release-then-press edge joins P1 and starts the run.
    if (world.phase() == GamePhase::Title) {
        in.fire = pulse_fire(state);
        return in;
    }

    // Knocked out: PlayerHealthSystem reads fire at level, but pulsing keeps
    // the same edge-clean shape as every other prompt.
    if (world.player_health(playerIndex).sittingOut) {
        in.fire = pulse_fire(state);
        return in;
    }

    const ReticleComponent& reticle = world.reticle(playerIndex);
    if (!reticle.active) return in;

    // Boss QTE: the ONLY way to damage a boss. Points ride the live boss's
    // projected box, so this tracks them the same way it tracks an animal.
    const BossMajorAttackState& attack = world.major_attack();
    if (attack.phase == MajorAttackPhase::Live) {
        int index = pick_major_attack_point(attack, reticle);
        if (index >= 0) {
            const BossMajorAttackPointState& point = attack.points[index];
            steer(in, reticle, point.screenX, point.screenY);
            float dx = reticle.x - point.screenX, dy = reticle.y - point.screenY;
            float reach = point.hitRadius * kFireMargin;
            in.fire = (dx * dx + dy * dy) <= reach * reach;
        }
        state.committedTarget = -1;
        return in;
    }
    if (attack.active()) return in;  // Preview / Result: nothing to shoot yet

    // Hold the committed target while it stays worth shooting, but hand over
    // the moment anything opens an interrupt window — that is the play.
    int committed = state.committedTarget;
    bool committedStillGood = committed >= 0 && world.target(committed).active;
    int fresh = pick_target(world);
    if (fresh >= 0) {
        const DinoBehaviorComponent* freshDino = dino_for_target(world, fresh);
        if (!committedStillGood || (freshDino && freshDino->interruptWindowOpen)) {
            committed = fresh;
        }
    } else if (!committedStillGood) {
        committed = -1;
    }
    state.committedTarget = committed;

    if (committed < 0) {
        // Nothing on screen: ease back to center so the next wave arrives
        // with the reticle somewhere useful, rather than parked in a corner.
        steer(in, reticle, 0.5f, 0.5f);
        in.stickX *= 0.25f;
        in.stickY *= 0.25f;
        return in;
    }

    const TargetComponent& target = world.target(committed);
    // Take the weak point when the animal exposes one — double damage, and
    // it is the mechanic the legibility pass exists to teach.
    bool weakPoint = target.weakPointHalfW > 0.f && target.screenHalfH > 0.f;
    float aimY = weakPoint ? target.screenY + target.weakPointOffsetY : target.screenY;
    float reachX = weakPoint ? target.weakPointHalfW : target.screenHalfW;
    float reachY = weakPoint ? target.screenHalfH * 0.35f : target.screenHalfH;

    steer(in, reticle, target.screenX, aimY);
    in.fire = fabsf(reticle.x - target.screenX) <= reachX * kFireMargin
           && fabsf(reticle.y - aimY) <= reachY * kFireMargin;
    return in;
}
