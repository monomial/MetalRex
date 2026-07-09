#pragma once

#include "RailSpline.h"
#include <string>
#include <vector>

struct LookAtBeat {
    float distance = 0.f;
    RexVec3 target;
};

struct ChartEvent {
    float distance = 0.f;
    std::string type;
    std::string payloadJSON;
};

struct LevelChart {
    RailSpline rail;
    std::vector<LookAtBeat> lookAtBeats;
    std::vector<ChartEvent> events;
};

LevelChart ChartLoader_load_file(const char *path);
LevelChart ChartLoader_load_default();
