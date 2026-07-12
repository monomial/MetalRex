#pragma once
#include "Components.h"

// Per-species table of the 4 major-attack hit points, authored in the boss's
// own normalized body box (u right, v down; 0.5,0.5 = box center). Shared by
// the Live hit-test/markers (placed inside the boss's live projected screen
// box — see BossMajorAttackPoint_place) and the Preview portrait's marker
// reveal (the portrait shares the same body framing), so hit boxes and drawn
// markers can never drift apart.
//
// Only Trex is populated today — add a case per new boss species as its
// model/art ships; no other code changes needed (the portrait filename and
// this table are both already keyed off DinoSpecies).
const BossMajorAttackPoint* BossMajorAttackPoints_for(DinoSpecies species);

// Places an authored body-box point (u right, v down) into the boss's LIVE
// projected screen box, yielding viewport-normalized (x, y) matching
// ReticleComponent.x/y and TargetComponent.screenX/screenY (y up, 0..1). The
// box is recomputed every tick by RailCameraSystem, so calling this each tick
// makes the points ride the moving/animating dino for free.
inline void BossMajorAttackPoint_place(const BossMajorAttackPoint& point,
                                       float boxCenterX, float boxCenterY,
                                       float boxHalfW, float boxHalfH,
                                       float* outX, float* outY) {
    *outX = boxCenterX + (point.u - 0.5f) * 2.f * boxHalfW;
    *outY = boxCenterY + (0.5f - point.v) * 2.f * boxHalfH; // v-down -> y-up
}
