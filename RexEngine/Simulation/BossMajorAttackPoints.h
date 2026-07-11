#pragma once
#include "Components.h"

// Per-species table of the 4 major-attack hit points. Shared by the hit-test
// (ReticleSystem, via viewport-space conversion) and the marker draw
// (RexRenderer, via the portrait's own aspect-fill transform) so hit boxes
// and drawn markers can never visually drift apart.
//
// Only Trex is populated today — add a case per new boss species as its
// model/art ships; no other code changes needed (the portrait filename and
// this table are both already keyed off DinoSpecies).
const BossMajorAttackPoint* BossMajorAttackPoints_for(DinoSpecies species);

// Converts an authored image-normalized point (u right, v down, matching how
// the portrait PNG and CoreGraphics both address pixels) into viewport-
// normalized (x, y), matching ReticleComponent.x/y and TargetComponent's
// screenX/screenY convention (y up, both 0..1). Portrait art is required to
// match the HUD's fixed logical canvas aspect ratio (same as the title
// screen's own art), which makes this a trivial affine map with no
// dependency on the renderer or the loaded texture's actual pixel size.
inline void BossMajorAttackPoint_toViewport(const BossMajorAttackPoint& point,
                                            float* outX, float* outY) {
    *outX = point.u;
    *outY = 1.f - point.v;
}
