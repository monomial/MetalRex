#include "InputSystem.h"
#include "Simulation/World.h"
#include "Simulation/Systems/AnimationSystem.h"
#include <math.h>

static constexpr float kPlayerSpeed = 300.0f;

void InputSystem_update(World& world) {
    uint32_t count = world.entity_count();
    auto& tags = world.player_tags();

    for (EntityID id = 0; id < count; ++id) {
        if (!tags.present(id)) continue;

        const PlayerTagComponent& tag = tags.get(id);
        const InputState input = world.current_input(tag.playerIndex);

        float x = input.stickX;
        float y = input.stickY;
        float len = sqrtf(x * x + y * y);
        if (len > 1.f) {
            x /= len;
            y /= len;
        }

        if (world.has_component<VelocityComponent>(id)) {
            VelocityComponent& velocity = world.get_component<VelocityComponent>(id);
            velocity.vx = x * kPlayerSpeed;
            velocity.vy = y * kPlayerSpeed;
            velocity.vz = 0.f;
        }

        if (world.has_component<AnimationComponent>(id)) {
            bool moving = (x * x + y * y) > 0.01f;
            AnimationSystem_request_clip(world, id, moving ? CharacterClipSlot::Walk : CharacterClipSlot::Idle);
        }
    }
}
