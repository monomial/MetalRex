#pragma once
#include <simd/simd.h>

// Normalized input state produced each frame by InputSystem.
// All platforms (macOS keyboard/mouse, iOS touch, tvOS Siri Remote + gamepad)
// resolve to this struct before any game logic sees input.
struct InputState {
    float moveX;    // [-1, 1] normalized horizontal movement
    float moveY;    // [-1, 1] normalized vertical movement
    bool  attack;
    bool  dodge;
    bool  pause;
    bool  special;
};
