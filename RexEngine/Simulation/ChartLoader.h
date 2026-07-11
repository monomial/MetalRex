#pragma once

#include "RailSpline.h"
#include <stdint.h>
#include <string>
#include <vector>

struct LookAtBeat {
    float distance = 0.f;
    RexVec3 target;
};

struct RaptorWaveChartPayload {
    bool valid = false;
    uint8_t groupSize = 0;
    float lanes[3] = {0.f, 0.f, 0.f};
    float spawnGap = 8.f;
    float holdSeconds = 2.25f;
    float attackStaggerSeconds = 0.55f;
    std::string label;
};

struct ChartEvent {
    float distance = 0.f;
    std::string type;
    std::string payloadJSON;
    RaptorWaveChartPayload raptorWave;
};

// Per-level boss, authored in the chart's optional "boss" block — this is
// what makes "T-Rex level" vs "Triceratops level" a content decision rather
// than a code change (TODOS.md item 12). species must name a loadable
// character (validated at parse time, fails loudly on a typo); the numeric
// fields are optional and fall back to these defaults.
struct BossChartConfig {
    bool valid = false;
    std::string species = "trex";
    int maxHealth = 40;
    int attackDamage = 30;
    float attackRange = 3.2f;
    float chaseSpeed = 1.4f;
    float holdDuration = 2.8f;
};

struct LevelChart {
    RailSpline rail;
    std::vector<LookAtBeat> lookAtBeats;
    std::vector<ChartEvent> events;
    BossChartConfig boss;
};

LevelChart ChartLoader_load_file(const char *path);
LevelChart ChartLoader_load_default();
