#pragma once
#include <stdint.h>
#include <cassert>
#include "Components.h"

enum class EventType : uint8_t {
    None = 0,
    DinoScore,
};

struct Event {
    EventType type = EventType::None;
    uint8_t playerIndex = UINT8_MAX;
    DinoScoreEvent scoreEvent = DinoScoreEvent::Hit;
    DinoSpecies dinoSpecies = DinoSpecies::Velociraptor;
};

struct EventBus {
    static constexpr int kCapacity = 256;

    Event    slots[kCapacity];
    int      count = 0;
    uint32_t dropCount = 0;

    void clear() { count = 0; }

    void push(const Event& e) {
        if (count >= kCapacity) {
#ifdef NDEBUG
            ++dropCount;
            return;
#else
            assert(false && "EventBus overflow");
#endif
        }
        slots[count++] = e;
    }

    void push_dino_score(uint8_t playerIndex, DinoScoreEvent scoreEvent, DinoSpecies species) {
        Event e;
        e.type = EventType::DinoScore;
        e.playerIndex = playerIndex;
        e.scoreEvent = scoreEvent;
        e.dinoSpecies = species;
        push(e);
    }
};
