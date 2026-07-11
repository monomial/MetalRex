#include "World.h"
#include "Systems/InputSystem.h"
#include "Systems/RailCameraSystem.h"
#include "Systems/DinoBehaviorSystem.h"
#include "Systems/PlayerHealthSystem.h"
#include "Systems/ReticleSystem.h"
#include "Systems/ScoringSystem.h"
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
    , _nextChartEventIndex(0)
    , _levelComplete(false)
    , _phase(GamePhase::Playing)
    , _fireSeenReleased{}
    , _levelCompleteElapsed(0.f)
    , _levelCompleteFireReleased(false)
{
    _chart = ChartLoader_load_default();
    reset_m1_scene();
    // Default to a running 2P world — the sim tests drive gameplay directly
    // and predate the title flow. The real render host calls enter_title()
    // at launch, which deactivates these until players actually join.
    _reticles[0].active = true;
    _reticles[1].active = true;
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
    _nextChartEventIndex = 0;
    _levelComplete = false;
    _levelCompleteElapsed = 0.f;
    _levelCompleteFireReleased = false;
    for (EntityID id = 0; id < _nextID; ++id) {
        _animations.remove(id);
        _factions.remove(id);
        _dinoBehaviors.remove(id);
    }

    for (int i = 0; i < kRexMaxPlayers; ++i) {
        _playerHealth[i] = {};
        _playerScore[i] = {};
        // Preserve who's joined across resets: play-again restarts the run
        // for the same players, and the title flow (enter_title/join_player)
        // owns activation. P1 starts centered; P2 offset right so two
        // reticles don't stack before anyone moves them.
        bool wasActive = _reticles[i].active;
        _reticles[i] = {};
        _reticles[i].playerIndex = (uint8_t)i;
        _reticles[i].active = wasActive;
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
    // Raptors are a fixed pool. Chart-authored raptor_wave events claim 1-3
    // dormant slots, assign lanes/timing, and return them to dormancy after
    // the pounce/retreat cycle. That keeps the encounter predictable without
    // growing entities during a run.
    struct RaptorSpawn {
        int targetIndex;
        float railDistance;
        float lateralOffset;
        float chaseSpeed;
        float holdDuration;
    };
    static constexpr RaptorSpawn kRaptorSpawns[] = {
        {0, 3.0f, -1.9f, 3.55f, 0.9f},
        {1, 4.0f,  1.9f, 3.65f, 1.7f},
        {2, 3.3f, -1.1f, 3.50f, 2.3f},
        {3, 1.5f,  1.1f, 3.60f, 1.2f},
        {4, 4.2f, -0.4f, 3.58f, 2.0f},
        {5, 2.3f,  0.4f, 3.62f, 1.5f},
    };
    for (const RaptorSpawn& spawn : kRaptorSpawns) {
        TargetComponent& target = _targets[spawn.targetIndex];
        target.active = false;
        target.moving = true;
        target.railDistance = spawn.railDistance;
        target.baseLateralOffset = spawn.lateralOffset;
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
        dino.activeInEncounter = false;
        dino.targetIndex = (uint8_t)spawn.targetIndex;
        dino.species = DinoSpecies::Velociraptor;
        dino.state = DinoBehaviorState::Dormant;
        dino.chaseSpeed = spawn.chaseSpeed; // jeep runs 1.2 — raptor gains ground
        dino.attackRange = 2.4f;
        dino.holdDuration = spawn.holdDuration;
        dino.maxHealth = 3;
        dino.health = 3;
        dino.tellEndNormalized = 0.28f;
        dino.interruptStartNormalized = 0.18f;
        dino.interruptEndNormalized = 0.46f;
        dino.jumpReactionDuration = 0.35f;
        dino.retreatDuration = 1.2f;
        dino.retreatGap = 8.f;
    }

    // The boss gets its own centered lane (index 6, the 7th and last slot) —
    // biggest silhouette, framed center with raptors spread on both sides
    // rather than off to one side where it could share a lane with a raptor.
    // Species and stats come from the chart's optional "boss" block
    // (BossChartConfig defaults when absent) — different levels get
    // different bosses by authoring different charts, no code change.
    const BossChartConfig& bossConfig = _chart.boss; // defaults are the classic T-Rex
    DinoSpecies bossSpecies = bossConfig.species == "velociraptor"
                            ? DinoSpecies::Velociraptor : DinoSpecies::Trex;
    bool bossIsTrex = (bossSpecies == DinoSpecies::Trex);

    bool bossArrivesLater = bossConfig.arrivalDistance > 0.f;
    _targets[6].active = !bossArrivesLater;
    _targets[6].moving = true;
    _targets[6].railDistance = 0.f;
    _targets[6].baseLateralOffset = 0.f;
    _targets[6].lateralOffset = 0.f;
    // Hit-box footprint follows the species' authored proportions (the
    // renderer derives visual scale from halfHeight — see the raptor spawn
    // comment above).
    _targets[6].halfWidth = bossIsTrex ? 1.0f : 0.4f;
    _targets[6].halfHeight = bossIsTrex ? 1.81f : 0.65f;

    EntityID boss = defer_create();
    AnimationComponent& bossAnim = add_component<AnimationComponent>(boss);
    bossAnim.currentClip = CharacterClipSlot::Idle;
    bossAnim.requestedClip = CharacterClipSlot::Idle;
    FactionComponent& bossFaction = add_component<FactionComponent>(boss);
    bossFaction.type = FactionComponent::Enemy;
    DinoBehaviorComponent& bossDino = add_component<DinoBehaviorComponent>(boss);
    bossDino.active = true;
    bossDino.activeInEncounter = !bossArrivesLater;
    bossDino.targetIndex = 6;
    bossDino.species = bossSpecies;
    bossDino.isBoss = true;
    bossDino.bossArrivalDistance = bossConfig.arrivalDistance;
    bossDino.state = bossArrivesLater ? DinoBehaviorState::Dormant
                                      : DinoBehaviorState::Approach;
    bossDino.chaseSpeed = bossConfig.chaseSpeed;   // heavy stomp — gains on the jeep slowly
    bossDino.attackRange = bossConfig.attackRange; // longer reach, lunges from farther out
    bossDino.holdDuration = bossConfig.holdDuration; // offset from the raptor waves
    bossDino.maxHealth = bossConfig.maxHealth;     // boss-weight: level ends when this drops
    bossDino.health = bossConfig.maxHealth;
    bossDino.tellEndNormalized = 0.28f;
    bossDino.interruptStartNormalized = 0.18f;
    bossDino.interruptEndNormalized = 0.46f;
    bossDino.jumpReactionDuration = 0.35f;
    bossDino.attackDamage = bossConfig.attackDamage; // heavier bite than a raptor's 15
    bossDino.retreatDuration = 1.8f;
    bossDino.retreatGap = 6.f;
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

void World::enter_title() {
    for (int i = 0; i < kRexMaxPlayers; ++i) {
        _reticles[i].active = false;
        _fireSeenReleased[i] = false;
    }
    reset_m1_scene();
    _phase = GamePhase::Title;
}

// Fresh slot for a player joining at the title or mid-run: full health,
// zero score, centered reticle. Mid-run joiners share the run in progress —
// the scene itself is only reset when the FIRST player starts from the
// title.
static void join_player(World& world, int player) {
    world.reticle(player).active = true;
    world.player_health(player) = {};
    world.score(player) = {};
}

void World::tick(float gameDt) {
    // Join edges — title and mid-run. A press counts only after that
    // player's fire has been seen released once (held triggers and launch
    // presses can't join anyone).
    for (int p = 0; p < kRexMaxPlayers; ++p) {
        if (_reticles[p].active) continue;
        if (!_inputs[p].fire) {
            _fireSeenReleased[p] = true;
        } else if (_fireSeenReleased[p]) {
            bool firstJoin = (_phase == GamePhase::Title);
            join_player(*this, p);
            if (firstJoin) {
                // First player in starts the run: fresh scene, off the title.
                reset_m1_scene();
                _phase = GamePhase::Playing;
            }
        }
    }
    if (_phase == GamePhase::Title) {
        flush();
        ++_tickCount;
        return;
    }
    InputSystem_update(*this);
    // Always ticks: it owns the hit-flash/invulnerability timers and is the
    // only thing watching for the "insert coin" fire press while frozen.
    PlayerHealthSystem_update(*this, gameDt);
    // Play-again flow: the LEVEL COMPLETE panel isn't a dead end — a fire
    // press restarts the whole scene. Two guards keep the trigger-mash that
    // just killed the T-Rex from skipping the panel before anyone sees it:
    // a short minimum display time, and fire must be seen RELEASED once
    // after completion before a press counts (a held trigger never
    // restarts, no matter how long it's held).
    if (_levelComplete) {
        _levelCompleteElapsed += gameDt;
        bool anyFire = false;
        for (int p = 0; p < kRexMaxPlayers; ++p) {
            if (_reticles[p].active && _inputs[p].fire) anyFire = true;
        }
        if (!anyFire) {
            _levelCompleteFireReleased = true;
        } else if (_levelCompleteFireReleased && _levelCompleteElapsed >= 1.5f) {
            reset_m1_scene();
        }
    }
    // Gameplay runs while at least one active player is still in. Sitting-out
    // players are skipped by ReticleSystem and damage targeting, while an
    // all-out state freezes rail/dinos/reticles/animation until someone
    // continues.
    if (!_levelComplete && any_player_active_and_not_sitting_out()) {
        RailCameraSystem_update(*this, gameDt);
        ReticleSystem_update(*this, gameDt);
        DinoBehaviorSystem_update(*this, gameDt);
        ScoringSystem_update(*this, gameDt);
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
