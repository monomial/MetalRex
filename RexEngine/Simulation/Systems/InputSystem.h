#pragma once
class World;

// Reads World::current_input(), finds the player entity (PlayerTagComponent),
// and writes VelocityComponent from the normalized move axes.
// Uses physicalDt conceptually — always runs, even during HitStop —
// but sets velocity in units/sec so PhysicsSystem (gameDt) controls actual movement.
void InputSystem_update(World& world);
