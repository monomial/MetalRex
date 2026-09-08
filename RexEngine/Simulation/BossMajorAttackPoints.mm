#include "BossMajorAttackPoints.h"

// Placeholder positions in the boss's body box (roughly: left brow, right
// brow, jaw/throat, chest) — tuned against the real T-Rex silhouette / portrait
// art once it exists. Spread across the box so the four targets read as
// distinct points on the body rather than a tight cluster. The CoreGraphics
// fallback portrait (RexRenderer.mm) draws numbered circles at these same
// coordinates, so the feature is playable before the real art arrives.
static const BossMajorAttackPoint kTrexPoints[kBossMajorAttackPointCount] = {
    {0.34f, 0.26f, 0.06f},
    {0.66f, 0.26f, 0.06f},
    {0.50f, 0.50f, 0.07f},
    {0.50f, 0.76f, 0.07f},
};

const BossMajorAttackPoint* BossMajorAttackPoints_for(DinoSpecies species) {
    switch (species) {
        case DinoSpecies::Trex:
            return kTrexPoints;
        case DinoSpecies::Velociraptor:
        case DinoSpecies::Triceratops:
        case DinoSpecies::Stegosaurus:
        case DinoSpecies::Parasaurolophus:
        case DinoSpecies::Apatosaurus:
        case DinoSpecies::Count:
            break;
    }
    // No boss species other than Trex has an authored table yet; fall back to
    // its rather than returning null so a caller can't crash on a missing
    // case. The herbivores are listed explicitly instead of behind a default:
    // so that adding a SEVENTH species warns here again — that warning is the
    // reminder that a new boss needs its own points.
    return kTrexPoints;
}
