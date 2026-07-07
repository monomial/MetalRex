#pragma once
#include <stdint.h>
#include <cassert>

// Event types — add new entries here and a handler in the relevant system.
enum class EventType : uint8_t {
    None = 0,
    DamageDealt,   // entity took damage
    EntityDied,    // entity HP hit 0, queued for destroy
    HitContact,    // attack landed (triggers hit-stop + shake)
    AttackStarted, // an Attack/Attack2 clip actually began (audio: swing whoosh)
    DodgeStarted,  // a Dodge clip actually began (audio + haptics)
    BossTelegraph, // boss is winding up a charge (audio + warning particles)
    BossEnraged,   // boss crossed half HP and entered phase two
    SpecialUsed,   // player spent a full special meter
    PickupCollected, // player collected a health pickup
    SecondWindUsed, // player consumed a Second Wind save instead of dying
    PlayerDowned,  // multiplayer player entered revive state
    PlayerRevived, // player was revived by a teammate
    WaveStarted,   // spawn markers appeared for a wave
    SpawnLanded,   // spawn animation completed
    FinalKill,      // true last enemy of the room was killed
    ExitReached,    // post-upgrade exit portal was entered
    ScrapCollected, // player collected scrap currency
    BoxBroken,      // breakable crate was destroyed
    ShopPurchase,   // shop pedestal bought
    LavaPoolSpawned, // lob landed and created a lava pool
    ChargeReady,    // player held attack long enough to charge
    ChargedSlam,    // charged heavy attack fired
    Evaded,         // passive dodge chance negated incoming player damage
};

struct DamageDealtPayload   { uint32_t targetID; int amount; };
struct EntityDiedPayload    { uint32_t entityID; };
struct HitContactPayload    { uint32_t attackerID; uint32_t targetID; };
struct AttackStartedPayload { uint32_t entityID; uint8_t clipID; }; // clipID = (uint8_t)AnimClipID
struct DodgeStartedPayload  { uint32_t entityID; };
struct BossTelegraphPayload { uint32_t entityID; };
struct BossEnragedPayload   { uint32_t entityID; };
struct SpecialUsedPayload   { uint32_t entityID; };
struct PickupCollectedPayload { uint32_t playerID; };
struct SecondWindUsedPayload { uint32_t playerID; };
struct PlayerDownedPayload  { uint32_t playerID; };
struct PlayerRevivedPayload { uint32_t playerID; };
struct WaveStartedPayload   { uint8_t waveIndex; };
struct SpawnLandedPayload   { uint32_t entityID; uint8_t style; };
struct FinalKillPayload     { uint32_t killerID; uint32_t victimID; };
struct ExitReachedPayload   { uint32_t entityID; bool cursed; uint8_t curseType; };
struct ScrapCollectedPayload { int value; };
struct BoxBrokenPayload     { float x; float y; uint8_t hadScrap; };
struct ShopPurchasePayload  { uint8_t perkID; int price; uint32_t itemEID; };
struct LavaPoolSpawnedPayload { float x; float y; };
struct ChargeReadyPayload   { uint32_t playerID; };
struct ChargedSlamPayload   { float x; float y; };
struct EvadedPayload        { uint32_t playerID; };

// One slot in the ring buffer.
struct Event {
    EventType type;
    union {
        DamageDealtPayload   damageDealt;
        EntityDiedPayload    entityDied;
        HitContactPayload    hitContact;
        AttackStartedPayload attackStarted;
        DodgeStartedPayload  dodgeStarted;
        BossTelegraphPayload bossTelegraph;
        BossEnragedPayload   bossEnraged;
        SpecialUsedPayload   specialUsed;
        PickupCollectedPayload pickupCollected;
        SecondWindUsedPayload secondWindUsed;
        PlayerDownedPayload  playerDowned;
        PlayerRevivedPayload playerRevived;
        WaveStartedPayload   waveStarted;
        SpawnLandedPayload   spawnLanded;
        FinalKillPayload     finalKill;
        ExitReachedPayload   exitReached;
        ScrapCollectedPayload scrapCollected;
        BoxBrokenPayload     boxBroken;
        ShopPurchasePayload  shopPurchase;
        LavaPoolSpawnedPayload lavaPoolSpawned;
        ChargeReadyPayload   chargeReady;
        ChargedSlamPayload   chargedSlam;
        EvadedPayload        evaded;
    };
};

// 256-slot single-frame ring buffer. Zero heap allocation.
// Overflow policy: assert in debug, silent drop + increment counter in release.
// Cleared at the start of each frame by World::tick().
struct EventBus {
    static constexpr int kCapacity = 256;

    Event    slots[kCapacity];
    int      count       = 0;
    uint32_t dropCount   = 0; // incremented on overflow in release

    void clear() { count = 0; }

    void push(const Event& e) {
        if (count >= kCapacity) {
#ifdef NDEBUG
            ++dropCount;
            return;
#else
            assert(false && "EventBus overflow — increase kCapacity or flush more often");
#endif
        }
        slots[count++] = e;
    }

    // Convenience emitters
    void emit_damage(uint32_t targetID, int amount) {
        Event e{}; e.type = EventType::DamageDealt;
        e.damageDealt = { targetID, amount };
        push(e);
    }
    void emit_died(uint32_t entityID) {
        Event e{}; e.type = EventType::EntityDied;
        e.entityDied = { entityID };
        push(e);
    }
    void emit_hit_contact(uint32_t attackerID, uint32_t targetID) {
        Event e{}; e.type = EventType::HitContact;
        e.hitContact = { attackerID, targetID };
        push(e);
    }
    void emit_attack_started(uint32_t entityID, uint8_t clipID) {
        Event e{}; e.type = EventType::AttackStarted;
        e.attackStarted = { entityID, clipID };
        push(e);
    }
    void emit_dodge_started(uint32_t entityID) {
        Event e{}; e.type = EventType::DodgeStarted;
        e.dodgeStarted = { entityID };
        push(e);
    }
    void emit_boss_telegraph(uint32_t entityID) {
        Event e{}; e.type = EventType::BossTelegraph;
        e.bossTelegraph = { entityID };
        push(e);
    }
    void emit_boss_enraged(uint32_t entityID) {
        Event e{}; e.type = EventType::BossEnraged;
        e.bossEnraged = { entityID };
        push(e);
    }
    void emit_special_used(uint32_t entityID) {
        Event e{}; e.type = EventType::SpecialUsed;
        e.specialUsed = { entityID };
        push(e);
    }
    void emit_pickup_collected(uint32_t playerID) {
        Event e{}; e.type = EventType::PickupCollected;
        e.pickupCollected = { playerID };
        push(e);
    }
    void emit_second_wind_used(uint32_t playerID) {
        Event e{}; e.type = EventType::SecondWindUsed;
        e.secondWindUsed = { playerID };
        push(e);
    }
    void emit_player_downed(uint32_t playerID) {
        Event e{}; e.type = EventType::PlayerDowned;
        e.playerDowned = { playerID };
        push(e);
    }
    void emit_player_revived(uint32_t playerID) {
        Event e{}; e.type = EventType::PlayerRevived;
        e.playerRevived = { playerID };
        push(e);
    }
    void emit_wave_started(uint8_t waveIndex) {
        Event e{}; e.type = EventType::WaveStarted;
        e.waveStarted = { waveIndex };
        push(e);
    }
    void emit_spawn_landed(uint32_t entityID, uint8_t style) {
        Event e{}; e.type = EventType::SpawnLanded;
        e.spawnLanded = { entityID, style };
        push(e);
    }
    void emit_final_kill(uint32_t killerID, uint32_t victimID) {
        Event e{}; e.type = EventType::FinalKill;
        e.finalKill = { killerID, victimID };
        push(e);
    }
    void emit_exit_reached(uint32_t entityID, bool cursed = false, uint8_t curseType = 0) {
        Event e{}; e.type = EventType::ExitReached;
        e.exitReached = { entityID, cursed, curseType };
        push(e);
    }
    void emit_scrap_collected(int value) {
        Event e{}; e.type = EventType::ScrapCollected;
        e.scrapCollected = { value };
        push(e);
    }
    void emit_box_broken(float x, float y, uint8_t hadScrap) {
        Event e{}; e.type = EventType::BoxBroken;
        e.boxBroken = { x, y, hadScrap };
        push(e);
    }
    void emit_shop_purchase(uint8_t perkID, int price, uint32_t itemEID) {
        Event e{}; e.type = EventType::ShopPurchase;
        e.shopPurchase = { perkID, price, itemEID };
        push(e);
    }
    void emit_lava_pool_spawned(float x, float y) {
        Event e{}; e.type = EventType::LavaPoolSpawned;
        e.lavaPoolSpawned = { x, y };
        push(e);
    }
    void emit_charge_ready(uint32_t playerID) {
        Event e{}; e.type = EventType::ChargeReady;
        e.chargeReady = { playerID };
        push(e);
    }
    void emit_charged_slam(float x, float y) {
        Event e{}; e.type = EventType::ChargedSlam;
        e.chargedSlam = { x, y };
        push(e);
    }
    void emit_evaded(uint32_t playerID) {
        Event e{}; e.type = EventType::Evaded;
        e.evaded = { playerID };
        push(e);
    }

    // Iterate all events of a given type.
    template<typename Fn>
    void for_each(EventType type, Fn fn) const {
        for (int i = 0; i < count; ++i)
            if (slots[i].type == type) fn(slots[i]);
    }
};
