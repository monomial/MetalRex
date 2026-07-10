#include "ScoringSystem.h"
#include <algorithm>

static void continue_streak(PlayerScoreState& score) {
    score.currentStreak += 1;
    score.bestStreak = std::max(score.bestStreak, score.currentStreak);
}

static void apply_score_event(PlayerScoreState& score, DinoScoreEvent event) {
    switch (event) {
        case DinoScoreEvent::Hit:
            score.score += 10;
            score.shotsHit += 1;
            continue_streak(score);
            break;
        case DinoScoreEvent::WeakPointHit:
            score.score += 25;
            score.shotsHit += 1;
            score.weakPointHits += 1;
            continue_streak(score);
            break;
        case DinoScoreEvent::InterruptSuccess:
            score.score += 50;
            score.shotsHit += 1;
            score.interruptSuccesses += 1;
            continue_streak(score);
            break;
        case DinoScoreEvent::InterruptFail:
        case DinoScoreEvent::TellMissed:
            score.currentStreak = 0;
            break;
    }
}

// ScoringSystem is the only reader of DinoScore events, so it doubles as the
// source of truth for this-frame audio cues (see AudioCueCounts in World.h) —
// RexGameHost reads the tally after World::update() to trigger sounds,
// without RexEngine itself depending on AVFoundation.
static void tally_audio_cue(AudioCueCounts& cues, DinoScoreEvent event) {
    switch (event) {
        case DinoScoreEvent::Hit:              cues.hits += 1; break;
        case DinoScoreEvent::WeakPointHit:      cues.weakPointHits += 1; break;
        case DinoScoreEvent::InterruptSuccess:  cues.interruptSuccesses += 1; break;
        case DinoScoreEvent::InterruptFail:     cues.interruptFails += 1; break;
        case DinoScoreEvent::TellMissed:        break;
    }
}

void ScoringSystem_update(World& world, float /*gameDt*/) {
    EventBus& events = world.events();
    for (int i = 0; i < events.count; ++i) {
        const Event& event = events.slots[i];
        if (event.type != EventType::DinoScore) continue;
        if (event.playerIndex >= kRexMaxPlayers) continue;
        apply_score_event(world.score(event.playerIndex), event.scoreEvent);
        tally_audio_cue(world.audio_cues(), event.scoreEvent);
    }
    events.clear();

    for (int player = 0; player < kRexMaxPlayers; ++player) {
        if (!world.reticle(player).active) continue;
        world.score(player).shotsFired = (int)world.reticle(player).shotCount;
    }
}
