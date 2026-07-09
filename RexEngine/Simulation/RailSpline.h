#pragma once

#include <stdint.h>
#include <vector>

struct RexVec3 {
    float x = 0.f;
    float y = 0.f;
    float z = 0.f;
};

RexVec3 RexVec3_add(RexVec3 a, RexVec3 b);
RexVec3 RexVec3_sub(RexVec3 a, RexVec3 b);
RexVec3 RexVec3_scale(RexVec3 v, float s);
float   RexVec3_length(RexVec3 v);

struct RailSample {
    float distance = 0.f;
    float rawT = 0.f;
};

class RailSpline {
public:
    void build(const std::vector<RexVec3>& controlPoints, int samplesPerSegment = 48);

    bool valid() const { return _valid; }
    float total_length() const { return _totalLength; }
    int segment_count() const;
    const std::vector<RexVec3>& control_points() const { return _points; }
    const std::vector<RailSample>& arc_table() const { return _arcTable; }

    RexVec3 position_at_raw_t(float rawT) const;
    RexVec3 tangent_at_raw_t(float rawT) const;
    float raw_t_at_distance(float distance) const;
    RexVec3 position_at_distance(float distance) const;
    RexVec3 tangent_at_distance(float distance) const;

private:
    RexVec3 point_for_segment(int segment, int offset) const;

    std::vector<RexVec3> _points;
    std::vector<RailSample> _arcTable;
    float _totalLength = 0.f;
    bool _valid = false;
};
