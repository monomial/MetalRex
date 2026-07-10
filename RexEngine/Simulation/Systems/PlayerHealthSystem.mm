#include "PlayerHealthSystem.h"
#include <algorithm>

void PlayerHealthSystem_update(World& world, float gameDt) {
    for (int p = 0; p < kRexMaxPlayers; ++p) {
        if (!world.reticle(p).active) continue;

        PlayerHealthState& health = world.player_health(p);

        if (health.hitFlashTime > 0.f) {
            health.hitFlashTime = std::max(0.f, health.hitFlashTime - gameDt);
        }
        if (health.invulnTime > 0.f) {
            health.invulnTime = std::max(0.f, health.invulnTime - gameDt);
        }

        if (!health.sittingOut) continue;

        // Read raw input directly (not via ReticleSystem) since the reticle
        // system skips sitting-out players and the all-out state pauses
        // reticle updates completely.
        if (world.current_input(p).fire) {
            health.health = health.maxHealth;
            health.sittingOut = false;
            // Grace window so the player isn't instantly re-hit by whatever
            // dino was mid-attack when they continued.
            health.invulnTime = 1.5f;
        }
    }
}
