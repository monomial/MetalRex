#include "PlayerHealthSystem.h"
#include <algorithm>

void PlayerHealthSystem_update(World& world, float gameDt) {
    PlayerHealthState& health = world.player_health();

    if (health.hitFlashTime > 0.f) {
        health.hitFlashTime = std::max(0.f, health.hitFlashTime - gameDt);
    }
    if (health.invulnTime > 0.f) {
        health.invulnTime = std::max(0.f, health.invulnTime - gameDt);
    }

    if (!health.gameOver) return;

    // Any active player's trigger inserts the coin. Read raw input directly
    // (not via ReticleSystem) since the reticle/dino systems are paused for
    // the whole gameOver duration — there's no per-frame "was this the first
    // tick of the press" edge to track here because World::tick simply stops
    // calling this branch once continuePressed flips gameOver off.
    bool continuePressed = false;
    for (int p = 0; p < kRexMaxPlayers; ++p) {
        if (!world.reticle(p).active) continue;
        if (world.current_input(p).fire) {
            continuePressed = true;
            break;
        }
    }
    if (!continuePressed) return;

    health.health = health.maxHealth;
    health.gameOver = false;
    // Grace window so the player isn't instantly re-hit by whatever dino was
    // mid-attack when the game froze.
    health.invulnTime = 1.5f;
}
