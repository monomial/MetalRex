#pragma once
#include "Simulation/World.h"
struct LoadedCharacter;

// Call once at startup to supply character mesh data for bone matrix sampling.
// Either pointer may be null (animation timers still advance, bone matrices stay identity).
void AnimationSystem_set_characters(const LoadedCharacter* player,
                                    const LoadedCharacter* enemy);

// Advances clip time + samples bone matrices for every entity with an AnimationComponent.
// Uses gameDt — animation freezes during HitStop along with physics.
void AnimationSystem_update(World& world, float gameDt);

// Request a clip transition. Sets requestedClip; AnimationSystem handles the
// actual transition at the next safe frame boundary.
void AnimationSystem_request_clip(World& world, EntityID entity, AnimClipID clip);

// Returns the duration of a clip for the given entity (uses loaded character data
// when available, falls back to compile-time constants). Used by CombatSystem to
// compute active-frame windows in absolute seconds.
float AnimationSystem_clip_duration(World& world, EntityID entity, AnimClipID clip);
