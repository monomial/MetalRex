#pragma once
#include <stdint.h>
#include <vector>
#include <cassert>
#include <math.h>
#include "Components.h"
#include "EnemyArchetypes.h"
#include "Platform/InputState.h"
#include "EventBus.h"

using EntityID = uint32_t;
static constexpr EntityID kInvalidEntity = UINT32_MAX;

// One storage slot per component type.
// data[id] holds the component value; has[id] says whether this entity has it.
// Indexed directly by EntityID — no hash map, no indirection.
template<typename T>
struct ComponentStorage {
    std::vector<T>    data;
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

// Hand-rolled ECS World.
// Owns entity IDs, component storage vectors, and the system execution order.
//
// Frame contract:
//   World.update(physicalDt, gameDt) drives one frame.
//   physicalDt = wall-clock time (audio, haptics, screen shake, render — never freezes).
//   gameDt     = scaled game time (logic, physics, combat — HitStopSystem sets to 0).
//   Deferred creates/destroys buffer until flush() at end of frame.
class World {
public:
    World();
    ~World();

    void update(float physicalDt, float gameDt);

    // Trigger N physics ticks at gameDt=0 (combat freeze without pausing render/audio).
    void trigger_hit_stop(int ticks);
    void trigger_slow_motion(int ticks, float scale);
    float time_scale() const { return _slowMoTicks > 0 ? _slowMoScale : 1.f; }
    float slow_motion_duration_seconds() const;

    // Called by the platform layer once per render frame before update().
    // playerIndex 0–3 maps to the player entity with matching PlayerTagComponent.playerIndex.
    void       set_input(InputState input, int playerIndex = 0) {
        if (playerIndex >= 0 && playerIndex < 4) _inputs[playerIndex] = input;
    }
    InputState current_input(int playerIndex = 0) const {
        return (playerIndex >= 0 && playerIndex < 4) ? _inputs[playerIndex] : InputState{};
    }

    // Deferred lifecycle — buffered and applied at end of frame, after all systems run.
    EntityID defer_create();
    void     defer_destroy(EntityID id);

    // Component API — template methods dispatch to the matching storage member.
    template<typename T> T&   add_component(EntityID id);
    template<typename T> T&   get_component(EntityID id);
    template<typename T> bool has_component(EntityID id);
    template<typename T> void remove_component(EntityID id);

    uint32_t entity_count() const { return _nextID; }

    // Deterministic sim RNG (xorshift32). All gameplay randomness must come
    // from here — a seeded World with identical inputs replays identically,
    // which the headless scenario tests rely on.
    void set_seed(uint32_t seed) { _rngState = seed ? seed : 0x9E3779B9u; }
    uint32_t rand_u32() {
        uint32_t x = _rngState;
        x ^= x << 13; x ^= x >> 17; x ^= x << 5;
        return _rngState = x;
    }
    // Modulo bias is fine for gameplay-scale ranges.
    uint32_t rand_range(uint32_t n) { return n ? rand_u32() % n : 0; }
    float    rand_float01()         { return (float)(rand_u32() >> 8) * (1.0f / 16777216.0f); }

    void set_scrap(int scrap) { _scrap = scrap; }
    int scrap() const { return _scrap; }
    void set_difficulty(int level) { _difficulty = level; }
    int difficulty() const { return _difficulty; }
    void set_curse(float mult) { _curseMult = (mult > 0.f) ? mult : 1.f; }
    float curse_mult() const { return _curseMult; }
    int curse_damage(int base) const {
        int scaled = (int)lroundf((float)base * _curseMult);
        return scaled < 1 ? 1 : scaled;
    }
    // True during the victory window (set when the room's final kill triggers
    // slow-mo): players take no damage so lingering hazards can't chip them.
    void set_players_invincible(bool v) { _playersInvincible = v; }
    bool players_invincible() const { return _playersInvincible; }

    // Per-frame event bus — cleared at top of each tick, readable by all systems.
    EventBus& events() { return _events; }

    // Direct pool access for systems that iterate all entities with a component.
    ComponentStorage<PositionComponent>& positions()   { return _positions; }
    ComponentStorage<VelocityComponent>& velocities()  { return _velocities; }
    ComponentStorage<HealthComponent>&   healths()     { return _healths; }
    ComponentStorage<DownedComponent>&   downed()      { return _downed; }
    ComponentStorage<FactionComponent>&  factions()    { return _factions; }
    ComponentStorage<PlayerTagComponent>&      player_tags()      { return _playerTags; }
    ComponentStorage<DamageCooldownComponent>& damage_cooldowns() { return _damageCooldowns; }
    ComponentStorage<AnimationComponent>&      animations()       { return _animations; }
    ComponentStorage<FacingComponent>&             facings()          { return _facings; }
    ComponentStorage<EnemyAttackCooldownComponent>& attack_cooldowns() { return _attackCooldowns; }
    ComponentStorage<DodgeComponent>&              dodges()           { return _dodges; }
    ComponentStorage<DodgeChargesComponent>&       dodge_charges()    { return _dodgeCharges; }
    ComponentStorage<BossTagComponent>&            boss_tags()        { return _bossTags; }
    ComponentStorage<KnockbackComponent>&          knockbacks()       { return _knockbacks; }
    ComponentStorage<EnemyArchetypeComponent>&     archetypes()       { return _archetypes; }
    ComponentStorage<BossChargeComponent>&         boss_charges()     { return _bossCharges; }
    ComponentStorage<StatsComponent>&              stats()            { return _stats; }
    ComponentStorage<HazardComponent>&             hazards()          { return _hazards; }
    ComponentStorage<LavaLobComponent>&            lava_lobs()        { return _lavaLobs; }
    ComponentStorage<PathFollowComponent>&         paths()            { return _paths; }
    ComponentStorage<SpecialMeterComponent>&       special_meters()   { return _specialMeters; }
    ComponentStorage<HeartPickupComponent>&        heart_pickups()    { return _heartPickups; }
    ComponentStorage<ScrapPickupComponent>&        scrap_pickups()    { return _scrapPickups; }
    ComponentStorage<ExitComponent>&               exits()            { return _exits; }
    ComponentStorage<ProjectileComponent>&         projectiles()      { return _projectiles; }
    ComponentStorage<TelegraphLineComponent>&      telegraph_lines()  { return _telegraphLines; }
    ComponentStorage<LeaperComponent>&             leapers()          { return _leapers; }
    ComponentStorage<WaveControllerComponent>&     wave_controllers() { return _waveControllers; }
    ComponentStorage<SpawnMarkerComponent>&        spawn_markers()    { return _spawnMarkers; }
    ComponentStorage<SpawnAnimComponent>&          spawn_anims()      { return _spawnAnims; }
    ComponentStorage<ObstacleComponent>&           obstacles()        { return _obstacles; }
    ComponentStorage<BoxComponent>&                boxes()            { return _boxes; }
    ComponentStorage<ShopkeeperComponent>&         shopkeepers()      { return _shopkeepers; }
    ComponentStorage<ShopItemComponent>&           shop_items()       { return _shopItems; }
    ComponentStorage<ChargeAttackComponent>&       charge_attacks()   { return _chargeAttacks; }

private:
    void flush();

    // Each _pool<T>() specialization returns the matching storage member.
    // Specializations are defined in World.mm.
    template<typename T> ComponentStorage<T>& _pool();

    void tick(float gameDt); // one fixed-timestep physics step

    uint32_t _nextID;
    uint32_t _rngState;
    uint32_t _deferredDestroyCount;
    EntityID _deferredDestroy[256];
    EventBus   _events;         // cleared each tick
    float      _accumulator;    // leftover time between fixed ticks
    int        _hitStopTicks;   // remaining ticks at gameDt=0
    int        _slowMoTicks;    // remaining ticks at scaled fixed dt
    float      _slowMoScale;    // gameDt multiplier while slow-mo is active
    InputState _inputs[4];      // one slot per player (0–3), set by platform each render frame
    int        _scrap;          // delegate-mirrored run currency for deterministic shop logic
    int        _difficulty;     // 0-based room difficulty, mirrored by delegate at room load
    float      _curseMult;      // delegate-mirrored enemy HP/damage multiplier
    bool       _playersInvincible; // true during the victory/final-kill window

    ComponentStorage<PositionComponent>  _positions;
    ComponentStorage<VelocityComponent>  _velocities;
    ComponentStorage<HealthComponent>    _healths;
    ComponentStorage<DownedComponent>    _downed;
    ComponentStorage<FactionComponent>   _factions;
    ComponentStorage<PlayerTagComponent>      _playerTags;
    ComponentStorage<DamageCooldownComponent> _damageCooldowns;
    ComponentStorage<AnimationComponent>      _animations;
    ComponentStorage<FacingComponent>              _facings;
    ComponentStorage<EnemyAttackCooldownComponent> _attackCooldowns;
    ComponentStorage<DodgeComponent>              _dodges;
    ComponentStorage<DodgeChargesComponent>       _dodgeCharges;
    ComponentStorage<BossTagComponent>            _bossTags;
    ComponentStorage<KnockbackComponent>          _knockbacks;
    ComponentStorage<EnemyArchetypeComponent>     _archetypes;
    ComponentStorage<BossChargeComponent>         _bossCharges;
    ComponentStorage<StatsComponent>              _stats;
    ComponentStorage<HazardComponent>             _hazards;
    ComponentStorage<LavaLobComponent>            _lavaLobs;
    ComponentStorage<PathFollowComponent>         _paths;
    ComponentStorage<SpecialMeterComponent>       _specialMeters;
    ComponentStorage<HeartPickupComponent>        _heartPickups;
    ComponentStorage<ScrapPickupComponent>        _scrapPickups;
    ComponentStorage<ExitComponent>               _exits;
    ComponentStorage<ProjectileComponent>         _projectiles;
    ComponentStorage<TelegraphLineComponent>      _telegraphLines;
    ComponentStorage<LeaperComponent>             _leapers;
    ComponentStorage<WaveControllerComponent>     _waveControllers;
    ComponentStorage<SpawnMarkerComponent>        _spawnMarkers;
    ComponentStorage<SpawnAnimComponent>          _spawnAnims;
    ComponentStorage<ObstacleComponent>           _obstacles;
    ComponentStorage<BoxComponent>                _boxes;
    ComponentStorage<ShopkeeperComponent>         _shopkeepers;
    ComponentStorage<ShopItemComponent>           _shopItems;
    ComponentStorage<ChargeAttackComponent>       _chargeAttacks;
};

// Template method bodies — inline here so all translation units can instantiate them.

template<typename T>
T& World::add_component(EntityID id)    { return _pool<T>().add(id); }

template<typename T>
T& World::get_component(EntityID id)    { return _pool<T>().get(id); }

template<typename T>
bool World::has_component(EntityID id)  { return _pool<T>().present(id); }

template<typename T>
void World::remove_component(EntityID id) { _pool<T>().remove(id); }

// Explicit specialization declarations — bodies are in World.mm.
template<> ComponentStorage<PositionComponent>&  World::_pool<PositionComponent>();
template<> ComponentStorage<VelocityComponent>&  World::_pool<VelocityComponent>();
template<> ComponentStorage<HealthComponent>&    World::_pool<HealthComponent>();
template<> ComponentStorage<DownedComponent>&    World::_pool<DownedComponent>();
template<> ComponentStorage<FactionComponent>&   World::_pool<FactionComponent>();
template<> ComponentStorage<PlayerTagComponent>&      World::_pool<PlayerTagComponent>();
template<> ComponentStorage<DamageCooldownComponent>& World::_pool<DamageCooldownComponent>();
template<> ComponentStorage<AnimationComponent>&      World::_pool<AnimationComponent>();
template<> ComponentStorage<FacingComponent>&              World::_pool<FacingComponent>();
template<> ComponentStorage<EnemyAttackCooldownComponent>& World::_pool<EnemyAttackCooldownComponent>();
template<> ComponentStorage<DodgeComponent>&              World::_pool<DodgeComponent>();
template<> ComponentStorage<DodgeChargesComponent>&       World::_pool<DodgeChargesComponent>();
template<> ComponentStorage<BossTagComponent>&            World::_pool<BossTagComponent>();
template<> ComponentStorage<KnockbackComponent>&          World::_pool<KnockbackComponent>();
template<> ComponentStorage<EnemyArchetypeComponent>&     World::_pool<EnemyArchetypeComponent>();
template<> ComponentStorage<BossChargeComponent>&         World::_pool<BossChargeComponent>();
template<> ComponentStorage<StatsComponent>&              World::_pool<StatsComponent>();
template<> ComponentStorage<HazardComponent>&             World::_pool<HazardComponent>();
template<> ComponentStorage<LavaLobComponent>&            World::_pool<LavaLobComponent>();
template<> ComponentStorage<PathFollowComponent>&         World::_pool<PathFollowComponent>();
template<> ComponentStorage<SpecialMeterComponent>&       World::_pool<SpecialMeterComponent>();
template<> ComponentStorage<HeartPickupComponent>&        World::_pool<HeartPickupComponent>();
template<> ComponentStorage<ScrapPickupComponent>&        World::_pool<ScrapPickupComponent>();
template<> ComponentStorage<ExitComponent>&               World::_pool<ExitComponent>();
template<> ComponentStorage<ProjectileComponent>&         World::_pool<ProjectileComponent>();
template<> ComponentStorage<TelegraphLineComponent>&      World::_pool<TelegraphLineComponent>();
template<> ComponentStorage<LeaperComponent>&             World::_pool<LeaperComponent>();
template<> ComponentStorage<WaveControllerComponent>&     World::_pool<WaveControllerComponent>();
template<> ComponentStorage<SpawnMarkerComponent>&        World::_pool<SpawnMarkerComponent>();
template<> ComponentStorage<SpawnAnimComponent>&          World::_pool<SpawnAnimComponent>();
template<> ComponentStorage<ObstacleComponent>&           World::_pool<ObstacleComponent>();
template<> ComponentStorage<BoxComponent>&                World::_pool<BoxComponent>();
template<> ComponentStorage<ShopkeeperComponent>&         World::_pool<ShopkeeperComponent>();
template<> ComponentStorage<ShopItemComponent>&           World::_pool<ShopItemComponent>();
template<> ComponentStorage<ChargeAttackComponent>&       World::_pool<ChargeAttackComponent>();
