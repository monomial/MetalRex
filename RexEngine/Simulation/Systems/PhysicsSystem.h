#pragma once
class World;

// Integrates VelocityComponent into PositionComponent each fixed tick.
// Uses gameDt — freezes to a no-op when HitStopSystem sets gameDt to 0.
void PhysicsSystem_update(World& world, float gameDt);
