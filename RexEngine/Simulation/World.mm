#include "World.h"
#include "Systems/InputSystem.h"
#include "Systems/RailCameraSystem.h"
#include "Systems/DinoBehaviorSystem.h"
#include "Systems/PlayerHealthSystem.h"
#include "Systems/ReticleSystem.h"
#include "Systems/AnimationSystem.h"
#import <Foundation/Foundation.h>
#include <algorithm>
#include <cassert>

static constexpr float kFixedDt = 1.0f / 120.0f;

template<> ComponentStorage<PositionComponent>& World::_pool() { return _positions; }
template<> ComponentStorage<VelocityComponent>& World::_pool() { return _velocities; }
template<> ComponentStorage<HealthComponent>& World::_pool() { return _healths; }
template<> ComponentStorage<FactionComponent>& World::_pool() { return _factions; }
template<> ComponentStorage<PlayerTagComponent>& World::_pool() { return _playerTags; }
template<> ComponentStorage<AnimationComponent>& World::_pool() { return _animations; }
template<> ComponentStorage<DinoBehaviorComponent>& World::_pool() { return _dinoBehaviors; }

World::World()
    : _nextID(0)
    , _rngState(0x9E3779B9u)
    , _deferredDestroyCount(0)
    , _events()
    , _accumulator(0.f)
    , _inputs{}
    , _tickCount(0)
{
    _chart = ChartLoader_load_default();
    reset_m1_scene();
}

World::~World() {}

EntityID World::defer_create() {
    return _nextID++;
}

void World::defer_destroy(EntityID id) {
    assert(_deferredDestroyCount < 256 && "deferred destroy buffer overflow");
    _deferredDestroy[_deferredDestroyCount++] = id;
}

void World::flush() {
    for (uint32_t i = 0; i < _deferredDestroyCount; ++i) {
        EntityID id = _deferredDestroy[i];
        _positions.remove(id);
        _velocities.remove(id);
        _healths.remove(id);
        _factions.remove(id);
        _playerTags.remove(id);
        _animations.remove(id);
        _dinoBehaviors.remove(id);
    }
    _deferredDestroyCount = 0;
}

void World::reset_m1_scene() {
    for (EntityID id = 0; id < _nextID; ++id) {
        _animations.remove(id);
        _factions.remove(id);
        _dinoBehaviors.remove(id);
    }

    for (int i = 0; i < kRexMaxPlayers; ++i) {
        _playerHealth[i] = {};
        _reticles[i] = {};
        _reticles[i].playerIndex = (uint8_t)i;
        // P1 and P2 both active (2P is a day-one design goal; a real join
        // flow lands in M5b). P1 starts centered; P2 starts offset right so
        // the two reticles don't stack before anyone moves them.
        _reticles[i].active = (i <= 1);
        _reticles[i].x = (i == 1) ? 0.62f : 0.5f;
        _reticles[i].y = 0.5f;
    }

    RailCameraSystem_reset(_railCamera, _chart);

    for (int i = 0; i < kM1MaxTargets; ++i) {
        _targets[i] = {};
        _targets[i].timerOffset = (float)i * 0.65f;
    }

    // Dino visual scale, not a hit-box tuning value: RexRenderer derives the
    // rendered mesh height directly from halfHeight (visualHeight =
    // halfHeight * 2). The relative sizes come from the authored assets —
    // in Blender world space the Quaternius raptor stands 5.46 units tall
    // and the T-Rex 15.22, a ratio of ~2.79 — so a 1.3-unit raptor pairs
    // with a 3.6-unit T-Rex. screenHalfH is still clamped to 0.20 in
    // RailCameraSystem, so a big dino can't blow up the on-screen hit box.
    //
    // Pursuers spawn BEHIND the jeep (the camera starts at rail distance 8
    // facing backward), deep enough that the player sees them run up. Each
    // raptor's idleDuration/chaseSpeed is staggered so their attack windows
    // roll rather than sync into one simultaneous scrum — a wave of pursuers
    // taking turns lunging, like the arcade reference, rather than all four
    // attacking in lockstep.
    struct RaptorSpawn {
        int targetIndex;
        float railDistance;
        float lateralOffset;
        float chaseSpeed;
        float idleDuration;
    };
    static constexpr RaptorSpawn kRaptorSpawns[] = {
        {0, 3.0f, -1.1f, 1.55f, 0.9f},
        {1, 4.6f,  1.1f, 1.65f, 1.7f},
        {2, 6.2f, -0.6f, 1.50f, 2.3f},
        {3, 1.5f,  0.0f, 1.60f, 1.2f},
    };
    for (const RaptorSpawn& spawn : kRaptorSpawns) {
        TargetComponent& target = _targets[spawn.targetIndex];
        target.active = true;
        target.moving = true;
        target.railDistance = spawn.railDistance;
        target.lateralOffset = spawn.lateralOffset;
        target.halfWidth = 0.4f;
        target.halfHeight = 0.65f;

        EntityID raptor = defer_create();
        AnimationComponent& anim = add_component<AnimationComponent>(raptor);
        anim.currentClip = CharacterClipSlot::Idle;
        anim.requestedClip = CharacterClipSlot::Idle;
        FactionComponent& faction = add_component<FactionComponent>(raptor);
        faction.type = FactionComponent::Enemy;
        DinoBehaviorComponent& dino = add_component<DinoBehaviorComponent>(raptor);
        dino.active = true;
        dino.targetIndex = (uint8_t)spawn.targetIndex;
        dino.species = DinoSpecies::Velociraptor;
        dino.chaseSpeed = spawn.chaseSpeed; // jeep runs 1.2 — raptor gains ground
        dino.attackRange = 2.4f;
        dino.idleDuration = spawn.idleDuration;
        dino.maxHealth = 3;
        dino.health = 3;
        dino.tellEndNormalized = 0.28f;
        dino.interruptStartNormalized = 0.18f;
        dino.interruptEndNormalized = 0.46f;
        dino.jumpReactionDuration = 0.35f;
    }

    _targets[4].active = true;
    _targets[4].moving = true;
    _targets[4].railDistance = 0.f;
    _targets[4].lateralOffset = 1.6f;
    _targets[4].halfWidth = 1.0f;
    _targets[4].halfHeight = 1.81f;

    EntityID trex = defer_create();
    AnimationComponent& trexAnim = add_component<AnimationComponent>(trex);
    trexAnim.currentClip = CharacterClipSlot::Idle;
    trexAnim.requestedClip = CharacterClipSlot::Idle;
    FactionComponent& trexFaction = add_component<FactionComponent>(trex);
    trexFaction.type = FactionComponent::Enemy;
    DinoBehaviorComponent& trexDino = add_component<DinoBehaviorComponent>(trex);
    trexDino.active = true;
    trexDino.targetIndex = 4;
    trexDino.species = DinoSpecies::Trex;
    trexDino.chaseSpeed = 1.4f;  // heavy stomp — gains on the jeep slowly
    trexDino.attackRange = 3.2f; // longer reach, lunges from farther out
    trexDino.idleDuration = 2.8f; // offset from the raptor wave so attacks don't sync
    trexDino.maxHealth = 8;      // boss-weight: soaks far more than a raptor
    trexDino.health = 8;
    trexDino.tellEndNormalized = 0.28f;
    trexDino.interruptStartNormalized = 0.18f;
    trexDino.interruptEndNormalized = 0.46f;
    trexDino.jumpReactionDuration = 0.35f;
    trexDino.attackDamage = 30; // heavier bite than a raptor's 15
}

bool World::any_player_active_and_not_sitting_out() const {
    for (int i = 0; i < kRexMaxPlayers; ++i) {
        if (_reticles[i].active && !_playerHealth[i].sittingOut) {
            return true;
        }
    }
    return false;
}

void World::damage_player(int playerIndex, int amount) {
    if (playerIndex < 0 || playerIndex >= kRexMaxPlayers) return;
    PlayerHealthState& health = _playerHealth[playerIndex];
    if (health.sittingOut || health.invulnTime > 0.f) return;
    health.health = std::max(0, health.health - amount);
    health.hitFlashTime = 0.35f;
    // Post-hit grace: without this, dinos whose attacks land in close
    // succession could stack damage from a single bad moment into an
    // instant death rather than a readable series of hits.
    health.invulnTime = 1.0f;
    if (health.health <= 0) {
        health.sittingOut = true;
    }
}

void World::replace_chart_for_tests(LevelChart chart) {
    _chart = chart;
    reset_m1_scene();
}

void World::tick(float gameDt) {
    InputSystem_update(*this);
    // Always ticks: it owns the hit-flash/invulnerability timers and is the
    // only thing watching for the "insert coin" fire press while frozen.
    PlayerHealthSystem_update(*this, gameDt);
    // Gameplay runs while at least one active player is still in. Sitting-out
    // players are skipped by ReticleSystem and damage targeting, while an
    // all-out state freezes rail/dinos/reticles/animation until someone
    // continues.
    if (any_player_active_and_not_sitting_out()) {
        RailCameraSystem_update(*this, gameDt);
        DinoBehaviorSystem_update(*this, gameDt);
        ReticleSystem_update(*this, gameDt);
        AnimationSystem_update(*this, gameDt);
    }
    flush();
    ++_tickCount;
}

void World::update(float physicalDt, float /*gameDt*/) {
    _events.clear();
    _accumulator += physicalDt;

    while (_accumulator >= kFixedDt) {
        _accumulator -= kFixedDt;
        tick(kFixedDt);
    }

    static uint64_t sLastLoggedSecond = UINT64_MAX;
    uint64_t seconds = _tickCount / 120;
    if (_tickCount > 0 && seconds != sLastLoggedSecond && (_tickCount % 120) == 0) {
        sLastLoggedSecond = seconds;
        NSLog(@"World::update fixed tick 120Hz accumulator: %llu ticks",
              (unsigned long long)_tickCount);
    }
}
