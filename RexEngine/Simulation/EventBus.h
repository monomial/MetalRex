#pragma once
#include <stdint.h>
#include <cassert>

enum class EventType : uint8_t {
    None = 0,
};

struct Event {
    EventType type = EventType::None;
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
};
