#pragma once
#include <stdint.h>
#include <vector>
#include <cassert>
#include "Components.h"
#include "Platform/InputState.h"
#include "EventBus.h"

using EntityID = uint32_t;
static constexpr EntityID kInvalidEntity = UINT32_MAX;

template<typename T>
struct ComponentStorage {
    std::vector<T> data;
    std::vector<bool> has;

    T& add(EntityID id) {
        if (id >= (EntityID)data.size()) {
            data.resize(id + 1);
            has.resize(id + 1, false);
        }
        has[id] = true;
        return data[id];
    }

    T& get(EntityID id) {
        assert(id < (EntityID)data.size() && has[id] && "get_component: entity missing component");
        return data[id];
    }

    bool present(EntityID id) const {
        return id < (EntityID)has.size() && has[id];
    }

    void remove(EntityID id) {
        if (id < (EntityID)has.size()) has[id] = false;
    }
};

class World {
public:
    World();
    ~World();

    void update(float physicalDt, float gameDt);

    void set_input(InputState input, int playerIndex = 0) {
        if (playerIndex >= 0 && playerIndex < kMaxPlayers) _inputs[playerIndex] = input;
    }
    InputState current_input(int playerIndex = 0) const {
        return (playerIndex >= 0 && playerIndex < kMaxPlayers) ? _inputs[playerIndex] : InputState{};
    }

    EntityID defer_create();
    void     defer_destroy(EntityID id);

    template<typename T> T&   add_component(EntityID id);
    template<typename T> T&   get_component(EntityID id);
    template<typename T> bool has_component(EntityID id);
    template<typename T> void remove_component(EntityID id);

    uint32_t entity_count() const { return _nextID; }
    uint64_t tick_count() const { return _tickCount; }

    void set_seed(uint32_t seed) { _rngState = seed ? seed : 0x9E3779B9u; }
    uint32_t rand_u32() {
        uint32_t x = _rngState;
        x ^= x << 13; x ^= x >> 17; x ^= x << 5;
        return _rngState = x;
    }
    uint32_t rand_range(uint32_t n) { return n ? rand_u32() % n : 0; }
    float rand_float01() { return (float)(rand_u32() >> 8) * (1.0f / 16777216.0f); }

    EventBus& events() { return _events; }

    ComponentStorage<PositionComponent>& positions() { return _positions; }
    ComponentStorage<VelocityComponent>& velocities() { return _velocities; }
    ComponentStorage<HealthComponent>& healths() { return _healths; }
    ComponentStorage<FactionComponent>& factions() { return _factions; }
    ComponentStorage<PlayerTagComponent>& player_tags() { return _playerTags; }
    ComponentStorage<ReticleComponent>& reticles() { return _reticles; }
    ComponentStorage<AnimationComponent>& animations() { return _animations; }

private:
    static constexpr int kMaxPlayers = 4;

    void flush();
    void tick(float gameDt);

    template<typename T> ComponentStorage<T>& _pool();

    uint32_t _nextID;
    uint32_t _rngState;
    uint32_t _deferredDestroyCount;
    EntityID _deferredDestroy[256];
    EventBus _events;
    float _accumulator;
    InputState _inputs[kMaxPlayers];
    uint64_t _tickCount;

    ComponentStorage<PositionComponent> _positions;
    ComponentStorage<VelocityComponent> _velocities;
    ComponentStorage<HealthComponent> _healths;
    ComponentStorage<FactionComponent> _factions;
    ComponentStorage<PlayerTagComponent> _playerTags;
    ComponentStorage<ReticleComponent> _reticles;
    ComponentStorage<AnimationComponent> _animations;
};

template<typename T>
T& World::add_component(EntityID id) { return _pool<T>().add(id); }

template<typename T>
T& World::get_component(EntityID id) { return _pool<T>().get(id); }

template<typename T>
bool World::has_component(EntityID id) { return _pool<T>().present(id); }

template<typename T>
void World::remove_component(EntityID id) { _pool<T>().remove(id); }

template<> ComponentStorage<PositionComponent>& World::_pool<PositionComponent>();
template<> ComponentStorage<VelocityComponent>& World::_pool<VelocityComponent>();
template<> ComponentStorage<HealthComponent>& World::_pool<HealthComponent>();
template<> ComponentStorage<FactionComponent>& World::_pool<FactionComponent>();
template<> ComponentStorage<PlayerTagComponent>& World::_pool<PlayerTagComponent>();
template<> ComponentStorage<ReticleComponent>& World::_pool<ReticleComponent>();
template<> ComponentStorage<AnimationComponent>& World::_pool<AnimationComponent>();
