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

struct LevelChart {
    RailSpline rail;
    std::vector<LookAtBeat> lookAtBeats;
    std::vector<ChartEvent> events;
};

LevelChart ChartLoader_load_file(const char *path);
LevelChart ChartLoader_load_default();
