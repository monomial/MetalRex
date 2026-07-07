#pragma once

struct InputState {
    float stickX;
    float stickY;
    float gyroDeltaX;
    float gyroDeltaY;
    bool  recenter;
    bool  fire;
    bool  pause;
};
