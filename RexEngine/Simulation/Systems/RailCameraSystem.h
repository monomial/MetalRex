#pragma once

class World;
struct LevelChart;
struct RailCameraState;

void RailCameraSystem_reset(RailCameraState& camera, const LevelChart& chart);
void RailCameraSystem_update(World& world, float gameDt);
