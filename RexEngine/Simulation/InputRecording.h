#pragma once
#include "Platform/InputState.h"
#include <stdint.h>
#include <string>
#include <vector>
#include <map>

// Named, diffable non-input fields. Values use the same nine-digit float contract
// as input rows. World supplies and validates the complete live schema.
struct ReplayHeader {
    std::map<std::string, std::string> fields;
    bool matches(const ReplayHeader& live, std::string* error = nullptr) const;
};

class InputRecording {
public:
    static constexpr uint32_t kFormatVersion = 1;

    explicit InputRecording(uint8_t playerCount = 1);

    ReplayHeader header;

    uint8_t playerCount() const { return _playerCount; }
    size_t tickCount() const { return _ticks.size(); }

    void appendTick(const InputState *inputs, uint8_t count);
    const InputState& inputAt(size_t tick, uint8_t playerIndex) const;

    bool saveToFile(const char *path, std::string *error = nullptr) const;
    // Parses transactionally. World::begin_replay must validate the header against
    // the selected seed/chart/build before any rows are allowed to run.
    bool loadFromFile(const char *path, std::string *error = nullptr);

private:
    uint8_t _playerCount;
    std::vector<std::vector<InputState>> _ticks;
};
