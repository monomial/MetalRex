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
// actual transition at the next safe frame boundary — for a non-looping
// clip (e.g. Attack), that means waiting for it to finish on its own first.
void AnimationSystem_request_clip(World& world, EntityID entity, CharacterClipSlot clip);

// Immediately begins the transition to `clip`, this tick, regardless of
// whether the current clip is looping or done — bypasses the "let a
// non-looping clip finish" rule. For genuinely interrupting an in-progress
// animation (e.g. a dino's Attack cut short by a successful player
// interrupt), where AnimationSystem_request_clip's graceful queuing would
// silently wait for Attack to finish before ever switching to the reaction
// clip, defeating the entire point of an interrupt.
void AnimationSystem_force_clip(World& world, EntityID entity, CharacterClipSlot clip);

// Returns the duration of a clip for the given entity.
float AnimationSystem_clip_duration(World& world, EntityID entity, CharacterClipSlot clip);
