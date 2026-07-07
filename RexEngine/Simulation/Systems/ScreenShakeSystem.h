#pragma once
#include <simd/simd.h>
class World;

// Manages a camera-offset that decays exponentially after trigger_screen_shake().
// Uses physicalDt — never freezes during HitStop (shake runs while game is frozen).
void ScreenShakeSystem_update(World& world, float physicalDt);

// Returns the current camera shake offset in world units (XY).
// RenderSystem adds this to the camera target each frame.
simd_float2 ScreenShakeSystem_offset(const World& world);

// Trigger a shake.
void ScreenShakeSystem_trigger(World& world, float magnitude);
