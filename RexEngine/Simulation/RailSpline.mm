#include "RailSpline.h"
#include <algorithm>
#include <cmath>
#include <stdexcept>

RexVec3 RexVec3_add(RexVec3 a, RexVec3 b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
RexVec3 RexVec3_sub(RexVec3 a, RexVec3 b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
RexVec3 RexVec3_scale(RexVec3 v, float s) { return {v.x * s, v.y * s, v.z * s}; }
float RexVec3_length(RexVec3 v) { return sqrtf(v.x * v.x + v.y * v.y + v.z * v.z); }

int RailSpline::segment_count() const {
    return _points.size() >= 2 ? (int)_points.size() - 1 : 0;
}

RexVec3 RailSpline::point_for_segment(int segment, int offset) const {
    int index = std::clamp(segment + offset, 0, (int)_points.size() - 1);
    return _points[(size_t)index];
}

void RailSpline::build(const std::vector<RexVec3>& controlPoints, int samplesPerSegment) {
    _points = controlPoints;
    _arcTable.clear();
    _totalLength = 0.f;
    _valid = false;

    if (_points.size() < 2) {
        throw std::runtime_error("RailSpline requires at least two control points");
    }
    samplesPerSegment = std::max(4, samplesPerSegment);

    _arcTable.push_back({0.f, 0.f});
    RexVec3 previous = position_at_raw_t(0.f);
    for (int segment = 0; segment < segment_count(); ++segment) {
        for (int sample = 1; sample <= samplesPerSegment; ++sample) {
            float local = (float)sample / (float)samplesPerSegment;
            float rawT = (float)segment + local;
            RexVec3 current = position_at_raw_t(rawT);
            float step = RexVec3_length(RexVec3_sub(current, previous));
            if (std::isfinite(step) && step > 0.f) {
                _totalLength += step;
                _arcTable.push_back({_totalLength, rawT});
            }
            previous = current;
        }
    }

    if (_totalLength <= 0.0001f || _arcTable.size() < 2) {
        throw std::runtime_error("RailSpline produced zero usable arc length");
    }
    _valid = true;
}

RexVec3 RailSpline::position_at_raw_t(float rawT) const {
    if (_points.empty()) return {};
    if (_points.size() == 1) return _points[0];

    rawT = std::clamp(rawT, 0.f, (float)segment_count());
    int segment = std::min((int)floorf(rawT), segment_count() - 1);
    float u = rawT - (float)segment;

    RexVec3 p0 = point_for_segment(segment, -1);
    RexVec3 p1 = point_for_segment(segment, 0);
    RexVec3 p2 = point_for_segment(segment, 1);
    RexVec3 p3 = point_for_segment(segment, 2);

    float u2 = u * u;
    float u3 = u2 * u;
    return {
        0.5f * ((2.f * p1.x) + (-p0.x + p2.x) * u
              + (2.f * p0.x - 5.f * p1.x + 4.f * p2.x - p3.x) * u2
              + (-p0.x + 3.f * p1.x - 3.f * p2.x + p3.x) * u3),
        0.5f * ((2.f * p1.y) + (-p0.y + p2.y) * u
              + (2.f * p0.y - 5.f * p1.y + 4.f * p2.y - p3.y) * u2
              + (-p0.y + 3.f * p1.y - 3.f * p2.y + p3.y) * u3),
        0.5f * ((2.f * p1.z) + (-p0.z + p2.z) * u
              + (2.f * p0.z - 5.f * p1.z + 4.f * p2.z - p3.z) * u2
              + (-p0.z + 3.f * p1.z - 3.f * p2.z + p3.z) * u3),
    };
}

RexVec3 RailSpline::tangent_at_raw_t(float rawT) const {
    if (_points.size() < 2) return {0.f, 0.f, 1.f};

    rawT = std::clamp(rawT, 0.f, (float)segment_count());
    int segment = std::min((int)floorf(rawT), segment_count() - 1);
    float u = rawT - (float)segment;

    RexVec3 p0 = point_for_segment(segment, -1);
    RexVec3 p1 = point_for_segment(segment, 0);
    RexVec3 p2 = point_for_segment(segment, 1);
    RexVec3 p3 = point_for_segment(segment, 2);

    float u2 = u * u;
    RexVec3 t = {
        0.5f * ((-p0.x + p2.x)
              + 2.f * (2.f * p0.x - 5.f * p1.x + 4.f * p2.x - p3.x) * u
              + 3.f * (-p0.x + 3.f * p1.x - 3.f * p2.x + p3.x) * u2),
        0.5f * ((-p0.y + p2.y)
              + 2.f * (2.f * p0.y - 5.f * p1.y + 4.f * p2.y - p3.y) * u
              + 3.f * (-p0.y + 3.f * p1.y - 3.f * p2.y + p3.y) * u2),
        0.5f * ((-p0.z + p2.z)
              + 2.f * (2.f * p0.z - 5.f * p1.z + 4.f * p2.z - p3.z) * u
              + 3.f * (-p0.z + 3.f * p1.z - 3.f * p2.z + p3.z) * u2),
    };
    float len = RexVec3_length(t);
    return len > 0.0001f ? RexVec3_scale(t, 1.f / len) : RexVec3_sub(p2, p1);
}

float RailSpline::raw_t_at_distance(float distance) const {
    if (_arcTable.empty()) return 0.f;
    if (distance <= 0.f) return _arcTable.front().rawT;
    if (distance >= _totalLength) return _arcTable.back().rawT;

    auto it = std::lower_bound(_arcTable.begin(), _arcTable.end(), distance,
                               [](const RailSample& sample, float value) {
                                   return sample.distance < value;
                               });
    if (it == _arcTable.begin()) return it->rawT;

    const RailSample& hi = *it;
    const RailSample& lo = *(it - 1);
    float span = hi.distance - lo.distance;
    if (span <= 0.000001f) return hi.rawT;
    float alpha = (distance - lo.distance) / span;
    return lo.rawT + (hi.rawT - lo.rawT) * alpha;
}

RexVec3 RailSpline::position_at_distance(float distance) const {
    return position_at_raw_t(raw_t_at_distance(distance));
}

RexVec3 RailSpline::tangent_at_distance(float distance) const {
    return tangent_at_raw_t(raw_t_at_distance(distance));
}
