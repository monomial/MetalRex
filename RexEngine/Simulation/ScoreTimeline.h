#pragma once
#include "Components.h"
#include <vector>
#include <string>
#include <algorithm>

struct ScoreTimelineEntry {
    uint64_t tickIndex;
    uint8_t player;
    DinoScoreEvent event;
    DinoSpecies species;
    bool operator==(const ScoreTimelineEntry&) const = default;
};
using ScoreTimeline = std::vector<ScoreTimelineEntry>;

// Empty means equal. Includes the first differing tick even for missing/extra events.
inline std::string ScoreTimeline_first_difference(const ScoreTimeline& a, const ScoreTimeline& b) {
    size_t i = 0;
    while (i < a.size() && i < b.size() && a[i] == b[i]) ++i;
    if (i == a.size() && i == b.size()) return {};
    uint64_t tick = i == a.size() ? b[i].tickIndex : i == b.size() ? a[i].tickIndex
        : std::min(a[i].tickIndex, b[i].tickIndex);
    auto describe = [&](const ScoreTimeline& timeline) {
        if (i == timeline.size()) return std::string("<end>");
        const auto& e = timeline[i];
        return std::to_string(e.tickIndex) + "/" + std::to_string(e.player) + "/"
            + std::to_string((int)e.event) + "/" + std::to_string((int)e.species);
    };
    return "first differing tickIndex " + std::to_string(tick) + ": " + describe(a) + " != " + describe(b);
}
