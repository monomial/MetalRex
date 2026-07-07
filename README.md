# MetalRex

Dino-mastery arcade rail shooter for tvOS/macOS — a Jurassic Park Arcade clone
where reading the animal's behavior tells IS the scoring system. Gyro-first
aim (DualSense/DualShock 4 via GCMotion), pure on-rails camera, 1P and 2P
co-op from the start screen.

Third game on a custom Metal/ObjC++ engine: Metal render pipeline, C++ ECS,
deterministic 120Hz fixed-tick sim, GameController input, native app shells,
and a skeletal animation stack (GPU skinning, baked-clip playback, cross-fade
blending) inherited from the first game on this engine. Engine sources are
vendored as a snapshot and free to diverge; shared engine extraction is
deliberately deferred (see docs/DESIGN.md Premise 5) even with three games now
sharing the lineage.

Design doc: [docs/DESIGN.md](docs/DESIGN.md)
Milestone 0/1 handoff plan: [docs/PLAN-M1.md](docs/PLAN-M1.md)
TODOs: [docs/TODOS.md](docs/TODOS.md)
