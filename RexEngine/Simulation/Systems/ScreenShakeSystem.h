#pragma once
#include <simd/simd.h>
class World;

// Manages a camera-offset that decays exponentially after trigger_screen_shake().
// Uses gameDt (real tick time, never slow-mo scaled) so a shake decays at a
// constant rate — it keeps running while the world is frozen or in bullet time.
void ScreenShakeSystem_update(World& world, float gameDt);

// Returns the current camera shake offset in world units (XY).
// RenderSystem adds this to the camera target each frame.
simd_float2 ScreenShakeSystem_offset(const World& world);

// Trigger a shake.
void ScreenShakeSystem_trigger(World& world, float magnitude);
