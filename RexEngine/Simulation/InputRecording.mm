#include "InputRecording.h"
#include <fstream>
#include <iomanip>
#include <sstream>
#include <locale>
#include <cmath>
#include <stdexcept>

InputRecording::InputRecording(uint8_t playerCount)
    : _playerCount(playerCount > 0 ? playerCount : 1)
    , _ticks()
{
    if (playerCount == 0 || playerCount > 4) throw std::invalid_argument("invalid replay playerCount");
}

bool ReplayHeader::matches(const ReplayHeader& live, std::string* error) const {
    for (const auto& [name, value] : live.fields) {
        auto it = fields.find(name);
        if (it == fields.end() || it->second != value) {
            if (error) *error = "replay mismatch: " + name + " (recorded "
                + (it == fields.end() ? "<missing>" : it->second) + ", live " + value + ")";
            return false;
        }
    }
    for (const auto& [name, value] : fields) {
        if (!live.fields.count(name)) {
            if (error) *error = "replay mismatch: " + name + " (unknown field)";
            return false;
        }
    }
    return true;
}

void InputRecording::appendTick(const InputState *inputs, uint8_t count) {
    std::vector<InputState> row;
    row.resize(_playerCount);
    for (uint8_t i = 0; i < _playerCount; ++i) {
        row[i] = (inputs && i < count) ? inputs[i] : InputState{};
    }
    _ticks.push_back(row);
}

const InputState& InputRecording::inputAt(size_t tick, uint8_t playerIndex) const {
    static const InputState empty{};
    if (tick >= _ticks.size() || playerIndex >= _playerCount) return empty;
    return _ticks[tick][playerIndex];
}

bool InputRecording::saveToFile(const char *path, std::string *error) const {
    std::ofstream out(path);
    if (!out) {
        if (error) *error = "could not open replay for writing";
        return false;
    }

    out.imbue(std::locale::classic());
    out << "metalrex_replay_v" << kFormatVersion << " "
        << (uint32_t)_playerCount << " " << _ticks.size() << "\n";
    out << "fields " << header.fields.size() << "\n";
    for (const auto& [name, value] : header.fields)
        out << std::quoted(name) << " " << std::quoted(value) << "\n";
    out << std::setprecision(9);
    for (const std::vector<InputState>& row : _ticks) {
        for (uint8_t i = 0; i < _playerCount; ++i) {
            const InputState& in = row[i];
            if (i > 0) out << " ";
            out << in.stickX << " " << in.stickY << " " << in.gyroDeltaX << " " << in.gyroDeltaY
                << " " << (in.recenter ? 1 : 0) << " " << (in.fire ? 1 : 0) << " " << (in.pause ? 1 : 0);
        }
        out << "\n";
    }

    out.close();
    if (!out) {
        if (error) *error = "failed while writing replay";
        return false;
    }
    return true;
}

bool InputRecording::loadFromFile(const char *path, std::string *error) {
    std::ifstream in(path);
    if (!in) {
        if (error) *error = "could not open replay for reading";
        return false;
    }

    in.imbue(std::locale::classic());
    std::string magic;
    uint32_t players = 0;
    size_t ticks = 0;
    if (!(in >> magic >> players >> ticks) || magic != "metalrex_replay_v1") {
        if (error) *error = "missing metalrex_replay_v1 header";
        return false;
    }
    if (players == 0 || players > 4) {
        if (error) *error = "invalid replay playerCount";
        return false;
    }

    ReplayHeader loadedHeader;
    std::string marker;
    size_t fields = 0;
    if (!(in >> marker >> fields) || marker != "fields" || fields > 4096) {
        if (error) *error = "invalid replay header fields";
        return false;
    }
    for (size_t i = 0; i < fields; ++i) {
        std::string name, value;
        if (!(in >> std::quoted(name) >> std::quoted(value))) {
            if (error) *error = "truncated replay header field " + name;
            return false;
        }
        if (!loadedHeader.fields.emplace(name, value).second) {
            if (error) *error = "duplicate replay header field " + name;
            return false;
        }
    }
    std::vector<std::vector<InputState>> loaded;
    // Do not reserve an untrusted tick count before reading any rows.
    for (size_t tick = 0; tick < ticks; ++tick) {
        std::vector<InputState> row;
        row.resize(players);
        for (uint32_t player = 0; player < players; ++player) {
            int recenter = 0, fire = 0, pause = 0;
            if (!(in >> row[player].stickX >> row[player].stickY >> row[player].gyroDeltaX >> row[player].gyroDeltaY >> recenter >> fire >> pause)) {
                if (error) *error = "truncated replay input stream";
                return false;
            }
            const auto& sample = row[player];
            if (!std::isfinite(sample.stickX) || !std::isfinite(sample.stickY)
                || !std::isfinite(sample.gyroDeltaX) || !std::isfinite(sample.gyroDeltaY)
                || recenter < 0 || recenter > 1 || fire < 0 || fire > 1 || pause < 0 || pause > 1) {
                if (error) *error = "invalid replay input at tick " + std::to_string(tick);
                return false;
            }
            row[player].recenter = recenter != 0;
            row[player].fire = fire != 0;
            row[player].pause = pause != 0;
        }
        loaded.push_back(row);
    }

    in >> std::ws;
    if (!in.eof()) {
        if (error) *error = "unexpected data after replay tickCount";
        return false;
    }
    header = std::move(loadedHeader);
    _playerCount = (uint8_t)players;
    _ticks = loaded;
    return true;
}
