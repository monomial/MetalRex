#include "World.h"
#include "Systems/InputSystem.h"
#include "Systems/RailCameraSystem.h"
#include "Systems/DinoBehaviorSystem.h"
#include "Systems/ReticleSystem.h"
#include "Systems/AnimationSystem.h"
#import <Foundation/Foundation.h>
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
        _reticles[i] = {};
        _reticles[i].playerIndex = (uint8_t)i;
        _reticles[i].active = (i == 0);
        _reticles[i].x = 0.5f;
        _reticles[i].y = 0.5f;
    }

    RailCameraSystem_reset(_railCamera, _chart);

    for (int i = 0; i < kM1MaxTargets; ++i) {
        _targets[i] = {};
        _targets[i].railDistance = 2.5f + (float)i * 1.4f;
        _targets[i].lateralOffset = ((i % 3) - 1) * 0.75f;
        // 0 = resting exactly on the ground (see RailCameraSystem's
        // ground-anchored Y computation) — was 0.35-0.53, a leftover from
        // the pre-M2 fake-perspective scheme that floated everything.
        _targets[i].verticalOffset = 0.f;
        _targets[i].timerOffset = (float)i * 0.65f;
        _targets[i].halfWidth = 0.18f;
        _targets[i].halfHeight = 0.22f;
    }

    _targets[0].active = true;
    _targets[1].active = true;
    _targets[2].active = true;

    // Dino visual scale, not a hit-box tuning value: RexRenderer derives the
    // rendered mesh height directly from halfHeight (visualHeight =
    // halfHeight * 2). The relative sizes come from the authored assets —
    // in Blender world space the Quaternius raptor stands 5.46 units tall
    // and the T-Rex 15.22, a ratio of ~2.79 — so a 1.3-unit raptor pairs
    // with a 3.6-unit T-Rex. screenHalfH is still clamped to 0.20 in
    // RailCameraSystem, so a big dino can't blow up the on-screen hit box.
    //
    // Pursuers spawn BEHIND the jeep (the camera starts at rail distance 8
    // facing backward), deep enough that the player sees them run up:
    // raptor 6.5 units back, T-Rex 8 back and to the side, both chasing
    // (see DinoBehaviorSystem).
    _targets[3].active = true;
    _targets[3].moving = true;
    _targets[3].railDistance = 1.5f;
    _targets[3].halfWidth = 0.4f;
    _targets[3].halfHeight = 0.65f;

    _targets[4].active = true;
    _targets[4].railDistance = 0.f;
    _targets[4].lateralOffset = 1.6f;
    _targets[4].halfWidth = 1.0f;
    _targets[4].halfHeight = 1.81f;

    EntityID raptor = defer_create();
    AnimationComponent& anim = add_component<AnimationComponent>(raptor);
    anim.currentClip = CharacterClipSlot::Idle;
    anim.requestedClip = CharacterClipSlot::Idle;
    FactionComponent& faction = add_component<FactionComponent>(raptor);
    faction.type = FactionComponent::Enemy;
    DinoBehaviorComponent& dino = add_component<DinoBehaviorComponent>(raptor);
    dino.active = true;
    dino.targetIndex = 3;
    dino.species = DinoSpecies::Velociraptor;
    dino.chaseSpeed = 1.6f;  // jeep runs 1.2 — raptor gains 0.4/s
    dino.attackRange = 2.4f;
    dino.idleDuration = 1.2f;
    dino.tellEndNormalized = 0.28f;
    dino.interruptStartNormalized = 0.18f;
    dino.interruptEndNormalized = 0.46f;
    dino.jumpReactionDuration = 0.35f;

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
    trexDino.idleDuration = 2.0f; // offset from the raptor so attacks don't sync
    trexDino.tellEndNormalized = 0.28f;
    trexDino.interruptStartNormalized = 0.18f;
    trexDino.interruptEndNormalized = 0.46f;
    trexDino.jumpReactionDuration = 0.35f;
}

void World::replace_chart_for_tests(LevelChart chart) {
    _chart = chart;
    reset_m1_scene();
}

void World::tick(float gameDt) {
    InputSystem_update(*this);
    RailCameraSystem_update(*this, gameDt);
    DinoBehaviorSystem_update(*this, gameDt);
    ReticleSystem_update(*this, gameDt);
    AnimationSystem_update(*this, gameDt);
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
