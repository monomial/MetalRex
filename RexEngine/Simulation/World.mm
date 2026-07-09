#include "World.h"
#include "Systems/InputSystem.h"
#include "Systems/RailCameraSystem.h"
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
    }
    _deferredDestroyCount = 0;
}

void World::reset_m1_scene() {
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
        _targets[i].verticalOffset = 0.35f + 0.18f * (float)(i % 2);
        _targets[i].timerOffset = (float)i * 0.65f;
        _targets[i].halfWidth = 0.18f;
        _targets[i].halfHeight = 0.22f;
    }

    _targets[0].active = true;
    _targets[1].active = true;
    _targets[2].active = true;
    _targets[3].active = true;
    _targets[3].moving = true;
    _targets[3].railDistance = 5.2f;
    _targets[3].halfWidth = 0.16f;
    _targets[3].halfHeight = 0.18f;
}

void World::replace_chart_for_tests(LevelChart chart) {
    _chart = chart;
    reset_m1_scene();
}

void World::tick(float gameDt) {
    InputSystem_update(*this);
    RailCameraSystem_update(*this, gameDt);
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
