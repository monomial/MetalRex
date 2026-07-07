# Milestone 0/1 Plan — Bootable Skeleton, then Reticle Feel

Workflow contract: **Claude plans and verifies; Codex implements.** Claude does
small mechanical steps (file copies, config, docs, one-line fixes) directly.
Every substantial coding task is one Codex run with explicit acceptance
criteria. Claude reviews the diff, builds, runs, and commits between tasks.

Design reference: [DESIGN.md](DESIGN.md). Relevant excerpts:

> M0 — Bootstrap (small): create repo; vendor a BrawlerEngine snapshot
> (render pipeline, ECS, fixed-tick sim, GameController input, AutoPilot,
> animation stack), stripping brawler-specific gameplay systems (CombatSystem,
> EnemyAISystem, and similar) that this game doesn't need; port runtime
> shader compilation in from MetalMoto, validated on real Apple TV hardware.
> macOS + tvOS targets build and run; AutoPilot headless target runs.
>
> M1 — Reticle (the go/no-go, 1P gameplay / 2P-shaped data): GCMotion gyro
> input, reticle rendering, stick-coarse + gyro-fine mixing, click-to-recenter,
> per-player H/V sensitivity, tiered smoothing near stillness; stick-only
> fallback with soft assist; a debug tuning HUD. Static pop-up targets on a
> timer, plus at least one moving 3D target tracked during actual camera rail
> motion. Gameplay is single player only — 2P join flow is deliberately
> deferred to M5 — but reticle/score/health state is represented as arrays
> over player-slot from the start. *Do not proceed until this is fun.*

## Vendor snapshot (Claude, mechanical — done in this commit)

Copied verbatim from `../MetalBrawler` (commit `11fceca`), renames deferred to
Codex task 1:

| Into MetalRex | From MetalBrawler | Status |
|---|---|---|
| `RexEngine/Platform/InputState.h` | `BrawlerEngine/Platform/InputState.h` | agnostic; fields become aim/reticle verbs in task 1 |
| `RexEngine/Simulation/World.{h,mm}` | same path | vendor-as-pattern: keep ECS machinery, 120Hz accumulator, xorshift RNG; task 1 replaces the brawler-specific system list with the skeleton tick order below |
| `RexEngine/Simulation/Components.h` | same path | keep Position/Velocity-style basics + `AnimationComponent`; task 1 deletes brawler-only components (combat, hazards, waves, etc.), adds a stub `ReticleComponent` |
| `RexEngine/Simulation/EventBus.h` | same path | keep ring buffer; task 1 replaces the brawler event enum |
| `RexEngine/Simulation/Systems/{Physics,ScreenShake,Input}System.*` | same path | agnostic; keep or prune per task 1's judgment — this game is pure-rails (Premise 1), so `PhysicsSystem` may end up unused/deleted |
| `RexEngine/Simulation/Systems/AnimationSystem.{h,mm}` | same path | **vendored now, not deferred** (unlike MetalMoto) — Premise 4 established this stack already exists and is core to the design from M3 onward; keep as-is, generalize the clip-ID model in the M3 task, not task 1 |
| `RexEngine/Assets/CharacterLoader.{h,mm}` | `BrawlerEngine/Assets/CharacterLoader.{h,mm}` | **vendored now**, same reasoning as AnimationSystem — untouched until the M3 task (per-species clip tables + load-time validation, per Premise 4) |
| `RexEngine/Renderer/BrawlerRenderer.{h,mm}` | same path | pipeline/camera reusable; task 1 strips the brawler draw loop, HUD, and any brawler-only component includes. **Shader loading already changed in this commit** — see below |
| `RexEngine/Renderer/ParticleSim.{cpp,h}` | same path | agnostic — candidate for hit-impact/dino-blood-spray particles later |
| `RexEngine/Audio/AudioEngine.{h,mm}` | same path | agnostic; `BRAWLER_MUTE` env → `REX_MUTE` in task 1 (already used in `scripts/smoke.sh`) |
| `RexEngine/Haptics/HapticsEngine.{h,mm}` | same path | agnostic |
| `Shaders/{Brawler,SkinnedMesh}.metal` | `Shaders/` | agnostic; **runtime-compiled as of this commit** (see below), renames deferred |
| `Rex-macOS/` | `Brawler-macOS/` minus `BrawlerAutoTest.*` | thin shell; task 1 retargets the game-init call |
| `Rex-tvOS/` | `Brawler-tvOS/` | thin shell; **tvOS included from M0** (unlike MetalMoto, which deferred tvOS to its M4) since tvOS is this game's lead platform. Already has multi-`GCController`-to-player-slot assignment for up to 4 controllers — reuse for M5b's co-op join, not rebuilt |
| `vendor-reference/BrawlerGameDelegate.{h,mm}` | `BrawlerEngine/` | NOT compiled. Source material: task 1 extracts the engine bootstrap (device/queue/semaphore init, `drawInMTKView:` → `advanceFrame:` loop, headless init, `rngSeedOverride`/`fixedFrameDt` hooks) into `RexGameHost`, discarding the brawler-specific gameplay rules. Delete this dir when task 1 lands. |
| `vendor-reference/AutoPilot.{h,mm}` | `BrawlerEngine/Simulation/` | NOT compiled. Source material only — the brawler AutoPilot's actual logic (hazard avoidance, combat engage distance, dodge timers) is 100% brawler-specific and does not transfer. What transfers is the *pattern*: a headless input-driver that ticks `World` deterministically and can be scripted from a fixed input log. MetalRex's M4b determinism milestone builds a rail-shooter-shaped equivalent from scratch using this as a reference for "how the existing engine does headless driving," not as code to adapt line-by-line. Delete this dir once M4b's replay driver exists. |
| `scripts/{run,smoke}.sh`, `.vscode/`, `.gitignore`, `.gitattributes`, `.github/workflows/ci.yml` | adapted from MetalMoto's versions, retargeted to Rex-macOS/Rex-tvOS | `env -u DYLD_LIBRARY_PATH` wrappers are load-bearing (Node injects `DYLD_LIBRARY_PATH` and breaks Metal apps); CI adds a tvOS build lane MetalMoto didn't need until its M4 |

**Shader loading (Claude, done in this commit — not deferred to Codex task 1):**
`RexEngine/Renderer/BrawlerRenderer.mm` no longer calls `[device
newDefaultLibrary]`. It reads `Shaders/Brawler.metal` and
`Shaders/SkinnedMesh.metal` from the bundle (both ship as plain resources,
`buildPhase: resources` in `project.yml` — no build-time `.metal` compilation),
concatenates their source, and compiles both via `newLibraryWithSource:` into
one library — mirroring MetalMoto's `MotoRenderer.mm` pattern, extended to two
files since this game needs the skinned-mesh pipeline from the start (dinos),
which MetalMoto didn't need yet. This is the reason the design doc calls
runtime shader compilation "ported in from MetalMoto": the Codex sandbox that
writes most of this code has no Metal toolchain, so shaders must compile at
launch from source, not at Xcode build time.

**Not vendored — deliberately left out of this engine snapshot:**
Brawler-specific gameplay systems (`CombatSystem`, `EnemyAISystem`,
`BossSystem`, `HazardSystem`, `KnockbackSystem`, `LavaLobSystem`,
`LeaperSystem`, `WaveSystem`, `ReviveSystem`, `RespawnSystem`, `DodgeSystem`,
`WallCollisionSystem`, `PickupSystem`, `ShopSystem`, `ExitSystem`,
`SpecialSystem`, `ContactDamageSystem`, `EnemyFactory`, `CombatHelpers`) — none
of this applies to a pure-rails dino-mastery shooter; there is no melee
combat, no rooms/waves, no shop. iOS shell (`Brawler-iOS`) — not a target
platform per the design doc's constraints.

## Codex task 1 — bootable skeleton

One Codex run. Acceptance criteria:
- `xcodegen && xcodebuild -scheme Rex-macOS -derivedDataPath .build/DerivedData build` succeeds with no warnings introduced by the restructuring.
- `xcodegen && xcodebuild -scheme Rex-tvOS -destination 'generic/platform=tvOS' -derivedDataPath .build/DerivedData build` succeeds (build only — no simulator/device run required for this task).
- `scripts/run.sh` opens a window on macOS: gray ground/clear color, 120Hz `World::update` accumulator ticking (log once per second to prove it).
- No file, type, env var, or string contains `Brawler` (grep-clean, except `docs/` and `vendor-reference/`, which is deleted once this task's extraction is complete).
- `World::tick()` runs exactly: `InputSystem` → `ReticleSystem` (stub, no-op — real logic is Codex task 2) → `AnimationSystem`. All brawler-only components/events deleted.
- `RexGameHost` (extracted from `vendor-reference/BrawlerGameDelegate`) supports headless init + `advanceFrame:` + `rngSeedOverride` + `fixedFrameDt`, matching what the brawler delegate provided — this is what makes `RexLogicTests` and, later, the M4b determinism harness possible.
- `InputState` becomes `{ float stickX; float stickY; float gyroDeltaX; float gyroDeltaY; bool recenter; bool fire; bool pause; }` — coarse-stick + fine-gyro fields per Premise 2, not brawler's `moveX/moveY/attack/dodge/special`.
- `RexLogicTests` (already scaffolded with `WorldSmokeTests.mm` in this commit) still passes.

## Codex task 2 — the actual M1: reticle + aim feel (the go/no-go)

One Codex run, after task 1 is committed. Acceptance criteria — see DESIGN.md's
M1 definition in full; the load-bearing points:
- GCMotion gyro input wired: `sensorsActive` management, controller
  connect/disconnect handled (not crashed on).
- Reticle rendering: a 2D screen-space crosshair per Premise 2 — the render
  camera never rotates based on aim input. `ReticleComponent` (real, not the
  task-1 stub) is **array/map-over-player-slot from the start**, even though
  only slot 0 is driven by gameplay this milestone (Premise 6's outside-voice
  fix — this avoids a single-player-shaped struct that gets refactored at M5b).
- Stick-coarse + gyro-fine mixing, click-to-recenter, per-player H/V
  sensitivity, tiered smoothing applied only near stillness (GyroWiki
  conventions) — treated as a *starting hypothesis to feel-test*, not a fixed
  rule (see Premise 2's outside-voice caveat).
- Stick-only fallback: reticle friction + modest bullet magnetism, no hard
  snap-lock.
- A debug tuning HUD exposing sensitivity/smoothing constants live.
- Static pop-up targets on a timer, **plus at least one moving 3D target
  tracked during actual camera rail motion** — static targets alone don't
  validate the real game.
- *Do not proceed to M2 until this is fun on the actual TV.*

## Manual next steps (not Codex tasks — yours)

- **Confirm/acquire a DualSense or DualShock 4.** Gyro is PlayStation-only on
  tvOS; Xbox pads have no gyro.
- **GCMotion spike, before or alongside task 1/2:** on real Apple TV hardware,
  confirm `GCController.motion` reports usable DualSense/DS4 gyro data — rate,
  latency, noise. The entire "resurrected light gun" premise depends on this.
  This needs your physical hardware; it's not something Codex can verify from
  its sandbox.
- **Spend 20 minutes with a well-tuned gyro-aim game** (per The Assignment in
  DESIGN.md) to internalize the feel target before judging task 2's output.

## Verification (Claude, after each task)

```sh
cd ~/workspace/MetalRex
xcodegen
xcodebuild -scheme Rex-macOS -derivedDataPath .build/DerivedData build -quiet
xcodebuild -scheme Rex-tvOS -destination 'generic/platform=tvOS' -derivedDataPath .build/DerivedData build -quiet
xcodebuild -scheme RexLogicTests -destination 'platform=macOS' test   # task 1+
scripts/run.sh            # eyeball: window opens, no crash
```

## Out of scope for M0/M1

Rail spline + chart loading (M2), dinos/animation generalization (M3),
scoring/health (M4a), determinism/replay (M4b), Act 1 content + 2P join (M5a/M5b).
See DESIGN.md's Next Steps for the full milestone sequence and its System Tick
Ordering section for how the remaining five new systems (GyroInput, RailCamera,
DinoBehavior, Scoring, Health) slot in relative to what task 1 establishes here.
