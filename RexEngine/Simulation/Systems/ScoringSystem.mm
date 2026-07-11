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

void ScoringSystem_update(World& world, float /*gameDt*/) {
    EventBus& events = world.events();
    for (int i = 0; i < events.count; ++i) {
        const Event& event = events.slots[i];
        if (event.type != EventType::DinoScore) continue;
        if (event.playerIndex >= kRexMaxPlayers) continue;
        apply_score_event(world.score(event.playerIndex), event.scoreEvent);
    }
    events.clear();

    for (int player = 0; player < kRexMaxPlayers; ++player) {
        if (!world.reticle(player).active) continue;
        world.score(player).shotsFired = (int)world.reticle(player).shotCount;
    }
}

char ScoringSystem_letter_grade(const PlayerScoreState& score) {
    float accuracy = (float)score.shotsHit / (float)std::max(1, score.shotsFired);
    if (accuracy >= 0.80f && score.interruptSuccesses >= 3) return 'S';
    if (accuracy >= 0.65f) return 'A';
    if (accuracy >= 0.45f) return 'B';
    if (accuracy >= 0.25f) return 'C';
    return 'D';
}
