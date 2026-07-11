#include "BossMajorAttackPoints.h"

// Placeholder positions (roughly: left eye, right eye, jaw, chest/neck) —
// tuned against assets/ui/boss-trex-portrait.png once that art exists. The
// CoreGraphics fallback texture (RexRenderer.mm) draws its own numbered
// circles at these same coordinates, so the feature is playable before the
// real art arrives.
static const BossMajorAttackPoint kTrexPoints[kBossMajorAttackPointCount] = {
    {0.40f, 0.32f, 0.05f},
    {0.60f, 0.32f, 0.05f},
    {0.50f, 0.50f, 0.06f},
    {0.50f, 0.70f, 0.06f},
};

const BossMajorAttackPoint* BossMajorAttackPoints_for(DinoSpecies species) {
    switch (species) {
        case DinoSpecies::Trex:
            return kTrexPoints;
        case DinoSpecies::Velociraptor:
        case DinoSpecies::Count:
            break;
    }
    // No boss species other than Trex exists yet; fall back to its table
    // rather than returning null so a caller can't crash on a missing case.
    return kTrexPoints;
}
