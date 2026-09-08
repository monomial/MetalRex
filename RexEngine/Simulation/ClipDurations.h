#pragma once
#include "Components.h"
#include <array>

using ClipDurationTable = std::array<std::array<float, (int)CharacterClipSlot::Count>, (int)DinoSpecies::Count>;
// Quaternius assets: ceil(source seconds * 30) + 1 baked frames, divided by 30.
// This table owns simulation timing, whether or not presentation assets are loaded.
inline constexpr ClipDurationTable kClipDurations = {{
    {{ 76.f/30,  74.f/30, 18.f/30, 26.f/30, 35.f/30, 40.f/30}}, // Velociraptor
    {{ 76.f/30,  43.f/30, 29.f/30, 36.f/30, 45.f/30, 49.f/30}}, // Trex
    {{ 78.f/30,  89.f/30, 25.f/30, 24.f/30, 51.f/30, 55.f/30}}, // Triceratops
    {{ 78.f/30,  89.f/30, 25.f/30, 58.f/30, 45.f/30, 49.f/30}}, // Stegosaurus
    {{ 76.f/30,  36.f/30, 18.f/30, 26.f/30, 41.f/30, 40.f/30}}, // Parasaurolophus
    {{129.f/30, 158.f/30, 45.f/30, 58.f/30, 56.f/30, 49.f/30}}, // Apatosaurus
}};
inline constexpr float kClipDurationEpsilon = 0.00001f;
