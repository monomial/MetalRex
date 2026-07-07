#include "World.h"
#include "Systems/InputSystem.h"
#include "Systems/EnemyAISystem.h"
#include "Systems/PhysicsSystem.h"
#include "Systems/CombatSystem.h"
#include "Systems/WallCollisionSystem.h"
#include "Systems/AnimationSystem.h"
#include "Systems/ScreenShakeSystem.h"
#include "Systems/DodgeSystem.h"
#include "Systems/KnockbackSystem.h"
#include "Systems/BossSystem.h"
#include "Systems/HazardSystem.h"
#include "Systems/SpecialSystem.h"
#include "Systems/PickupSystem.h"
#include "Systems/ShopSystem.h"
#include "Systems/ExitSystem.h"
#include "Systems/ProjectileSystem.h"
#include "Systems/LavaLobSystem.h"
#include "Systems/LeaperSystem.h"
#include "Systems/WaveSystem.h"
#include "Systems/ReviveSystem.h"
#include <cassert>

static constexpr float kFixedDt = 1.0f / 120.0f; // 8.33ms physics tick

// _pool<T>() specializations — each returns the matching storage member.
// To add a new component type: add the member to World.h, then add a line here.
template<> ComponentStorage<PositionComponent>&  World::_pool() { return _positions; }
template<> ComponentStorage<VelocityComponent>&  World::_pool() { return _velocities; }
template<> ComponentStorage<HealthComponent>&    World::_pool() { return _healths; }
template<> ComponentStorage<DownedComponent>&    World::_pool() { return _downed; }
template<> ComponentStorage<FactionComponent>&   World::_pool() { return _factions; }
template<> ComponentStorage<PlayerTagComponent>&      World::_pool() { return _playerTags; }
template<> ComponentStorage<DamageCooldownComponent>& World::_pool() { return _damageCooldowns; }
template<> ComponentStorage<AnimationComponent>&      World::_pool() { return _animations; }
template<> ComponentStorage<FacingComponent>&              World::_pool() { return _facings; }
template<> ComponentStorage<EnemyAttackCooldownComponent>& World::_pool() { return _attackCooldowns; }
template<> ComponentStorage<DodgeComponent>&              World::_pool() { return _dodges; }
template<> ComponentStorage<DodgeChargesComponent>&       World::_pool() { return _dodgeCharges; }
template<> ComponentStorage<BossTagComponent>&            World::_pool() { return _bossTags; }
template<> ComponentStorage<KnockbackComponent>&          World::_pool() { return _knockbacks; }
template<> ComponentStorage<EnemyArchetypeComponent>&     World::_pool() { return _archetypes; }
template<> ComponentStorage<BossChargeComponent>&         World::_pool() { return _bossCharges; }
template<> ComponentStorage<StatsComponent>&              World::_pool() { return _stats; }
template<> ComponentStorage<HazardComponent>&             World::_pool() { return _hazards; }
template<> ComponentStorage<LavaLobComponent>&            World::_pool() { return _lavaLobs; }
template<> ComponentStorage<PathFollowComponent>&         World::_pool() { return _paths; }
template<> ComponentStorage<SpecialMeterComponent>&       World::_pool() { return _specialMeters; }
template<> ComponentStorage<HeartPickupComponent>&        World::_pool() { return _heartPickups; }
template<> ComponentStorage<ScrapPickupComponent>&        World::_pool() { return _scrapPickups; }
template<> ComponentStorage<ExitComponent>&               World::_pool() { return _exits; }
template<> ComponentStorage<ProjectileComponent>&         World::_pool() { return _projectiles; }
template<> ComponentStorage<TelegraphLineComponent>&      World::_pool() { return _telegraphLines; }
template<> ComponentStorage<LeaperComponent>&             World::_pool() { return _leapers; }
template<> ComponentStorage<WaveControllerComponent>&     World::_pool() { return _waveControllers; }
template<> ComponentStorage<SpawnMarkerComponent>&        World::_pool() { return _spawnMarkers; }
template<> ComponentStorage<SpawnAnimComponent>&          World::_pool() { return _spawnAnims; }
template<> ComponentStorage<ObstacleComponent>&           World::_pool() { return _obstacles; }
template<> ComponentStorage<BoxComponent>&                World::_pool() { return _boxes; }
template<> ComponentStorage<ShopkeeperComponent>&         World::_pool() { return _shopkeepers; }
template<> ComponentStorage<ShopItemComponent>&           World::_pool() { return _shopItems; }
template<> ComponentStorage<ChargeAttackComponent>&       World::_pool() { return _chargeAttacks; }

// ----

World::World()
    : _nextID(0)
    , _rngState(0x9E3779B9u)
    , _deferredDestroyCount(0)
    , _accumulator(0.0f)
    , _hitStopTicks(0)
    , _slowMoTicks(0)
    , _slowMoScale(1.f)
    , _inputs{}
    , _scrap(0)
    , _difficulty(0)
    , _curseMult(1.f)
    , _playersInvincible(false)
{}

World::~World() {}

EntityID World::defer_create() {
    return _nextID++;
}

void World::defer_destroy(EntityID id) {
    assert(_deferredDestroyCount < 256 && "deferred destroy buffer overflow");
    _deferredDestroy[_deferredDestroyCount++] = id;
}

void World::trigger_hit_stop(int ticks) {
    if (ticks > _hitStopTicks) _hitStopTicks = ticks;
}

void World::trigger_slow_motion(int ticks, float scale) {
    if (ticks > _slowMoTicks) _slowMoTicks = ticks;
    _slowMoScale = scale;
}

float World::slow_motion_duration_seconds() const {
    return (float)_slowMoTicks * kFixedDt;
}

void World::flush() {
    for (uint32_t i = 0; i < _deferredDestroyCount; ++i) {
        EntityID id = _deferredDestroy[i];
        _positions.remove(id);
        _velocities.remove(id);
        _healths.remove(id);
        _downed.remove(id);
        _factions.remove(id);
        _playerTags.remove(id);
        _damageCooldowns.remove(id);
        _animations.remove(id);
        _facings.remove(id);
        _attackCooldowns.remove(id);
        _dodges.remove(id);
        _dodgeCharges.remove(id);
        _bossTags.remove(id);
        _knockbacks.remove(id);
        _archetypes.remove(id);
        _bossCharges.remove(id);
        _stats.remove(id);
        _hazards.remove(id);
        _lavaLobs.remove(id);
        _paths.remove(id);
        _specialMeters.remove(id);
        _heartPickups.remove(id);
        _scrapPickups.remove(id);
        _exits.remove(id);
        _projectiles.remove(id);
        _telegraphLines.remove(id);
        _leapers.remove(id);
        _waveControllers.remove(id);
        _spawnMarkers.remove(id);
        _spawnAnims.remove(id);
        _obstacles.remove(id);
        _boxes.remove(id);
        _shopkeepers.remove(id);
        _shopItems.remove(id);
        _chargeAttacks.remove(id);
    }
    _deferredDestroyCount = 0;
}

void World::tick(float gameDt) {
    // NOTE: events are cleared in update(), not here — a frame can run several
    // ticks, and the delegate routes events to audio/particles/haptics once
    // per frame after update() returns. Clearing per tick silently discarded
    // every event except the last tick's (most hit sounds, sparks, haptics).

    // Systems run in declared order (see docs/ecs-vocabulary.md).
    // gameDt is 0 during HitStop — systems that use it freeze automatically.

    // 1. InputSystem — reads current_input(), writes player velocity
    InputSystem_update(*this);
    // 1.45. LeaperSystem — owns leaper telegraph/leap/recover states before AI.
    LeaperSystem_update(*this, gameDt);
    // 1.5. EnemyAISystem — steers enemies toward player
    EnemyAISystem_update(*this, gameDt);
    // 1.6. BossSystem — charge state machine, overrides AI velocity/clip while
    //      telegraphing/charging/recovering; owns DamageCooldown decrement
    BossSystem_update(*this, gameDt);
    // 1.7. HazardSystem — moves lava snakes along their loops, applies area
    //      damage to players inside (gated by DamageCooldown), expires them
    HazardSystem_update(*this, gameDt);
    // 1.75. KnockbackSystem — overrides AI/input velocity while an entity is
    //       being shoved (runs after the velocity writers, before integration)
    KnockbackSystem_update(*this, gameDt);
    // 1.8. ProjectileSystem — ranged shots integrate after knockback, before physics.
    ProjectileSystem_update(*this, gameDt);
    // 1.85. LavaLobSystem — airborne lava shots land into stationary hazards.
    LavaLobSystem_update(*this, gameDt);
    // 2. PhysicsSystem
    PhysicsSystem_update(*this, gameDt);
    // 2.5. WallCollisionSystem — clamp entities to room bounds
    WallCollisionSystem_update(*this, gameDt);
    // 2.75. SpecialSystem — spends player meter on a radial slam before normal combat.
    SpecialSystem_update(*this, gameDt);
    // 3. CombatSystem — handles both player→enemy and enemy→player attack hitboxes.
    //    ContactDamageSystem removed: enemies now deal damage through Attack animations,
    //    not passive proximity. Code kept in ContactDamageSystem.mm for hazard reuse later.
    CombatSystem_update(*this, gameDt);
    // 3.5. PickupSystem — lifetime + collection after combat can create hearts.
    PickupSystem_update(*this, gameDt);
    // 3.51. ShopSystem — purchases after pickup collection updates currency.
    ShopSystem_update(*this, gameDt);
    // 3.52. ExitSystem — post-upgrade portal, after combat/pickups.
    ExitSystem_update(*this, gameDt);
    // 3.55. WaveSystem — room enemy waves after pickups, before animation.
    WaveSystem_update(*this, gameDt);
    // 3.6. ReviveSystem — multiplayer teammates revive downed players after pickups.
    ReviveSystem_update(*this, gameDt);
    // 4. HitStopSystem — managed by _hitStopTicks / trigger_hit_stop()
    // 5. AnimationSystem — advances clip time, samples bone matrices when assets loaded
    AnimationSystem_update(*this, gameDt);
    // 6. DodgeSystem — arms invincibility + applies impulse when Dodge clip starts;
    //    removes DodgeComponent when clip finishes. Runs after AnimationSystem so
    //    clipDone is up-to-date.
    DodgeSystem_update(*this, gameDt);
    // 7. AudioSystem (physicalDt — run even during HitStop)
    // RespawnSystem removed: room progression in BrawlerGameDelegate owns enemy spawning.
    // 8. HapticsSystem   — TODO
    // 9. ScreenShakeSystem (fixed physical dt — must keep decaying during HitStop,
    //    when gameDt is 0, otherwise the shake freezes exactly when it matters most)
    ScreenShakeSystem_update(*this, kFixedDt);
    // 9. flush
    flush();
    // 10. RenderSystem — called by the render loop after update() returns
}

void World::update(float physicalDt, float /*gameDt*/) {
    _events.clear(); // fresh slate each frame — events accumulate across ticks

    // Accumulate wall-clock time and drain in fixed 120Hz steps.
    // Prevents hitbox tunneling and makes physics deterministic.
    _accumulator += physicalDt;
    while (_accumulator >= kFixedDt) {
        _accumulator -= kFixedDt;

        // HitStop: consume one frozen tick, then resume.
        float tickGameDt = kFixedDt;
        if (_hitStopTicks > 0) {
            tickGameDt = 0.0f;
            --_hitStopTicks;
        } else if (_slowMoTicks > 0) {
            tickGameDt = kFixedDt * _slowMoScale;
            --_slowMoTicks;
        }

        tick(tickGameDt);
    }
}
