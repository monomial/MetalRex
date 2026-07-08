# Milestone 2 Plan — Rail Camera + Chart Loader

Workflow contract: **Claude plans and verifies; Codex implements.** Same as M0/M1
(see docs/PLAN-M1.md) — Claude does small mechanical steps directly, Codex
implements with explicit acceptance criteria, Claude reviews/builds/tests/commits.

Design reference: [DESIGN.md](DESIGN.md). Relevant excerpts:

> Premise 1 — Pure rails. The camera follows an authored spline with scripted
> look-at targets. No free movement, ever. A level = rail path + spawn/event
> chart (data, not code). Chart events are keyed to distance along the rail...
> Distance is arc-length, not raw spline parameter — the loader precomputes an
> arc-length lookup table for each rail spline at chart-load time, so
> "distance along the rail" means constant physical distance regardless of how
> tight a curve is.
>
> M2 — Rail + chart: camera on an authored spline with look-at beats; level =
> JSON chart `{rail, events[]}` with distance-keyed events; charts re-read at
> launch (a save-triggered watcher is a later comfort feature, not required
> here).

## Where M1 left off

M1's `RailCameraState`/`ReticleSystem.mm` uses a placeholder: a hardcoded
constant-speed straight-line dolly (`camera.dollyZ = camera.elapsed *
camera.dollySpeed`), explicitly scoped that way because M1 only needed to
answer "does reticle tracking feel good while the camera is also moving,"
not build the real rail system. M1's test targets fake 3D via a manual
perspective divide (`perspective = 1.f / max(1.0f, relativeZ)`) directly in
`ReticleSystem.mm`, because `RexRenderer` currently only has an **orthographic**
projection (`make_ortho`) — no `make_perspective`/`make_look_at` exist yet.
(The original vendored engine had these; they weren't carried into M1's
minimal 2D test scene.)

M2 replaces both of these with the real thing.

## Scope

1. **Spline representation.** A Catmull-Rom spline (or equivalent standard
   curve — pick one, name it) through a list of authored 3D control points.
   This is the rail path.

2. **Arc-length parameterization (the load-bearing piece).** At chart-load
   time, precompute a lookup table mapping arc-length distance -> spline
   parameter t (sample the spline at many small t-increments, accumulate
   segment lengths, build a monotonic distance->t table). `RailCameraSystem`
   then advances "distance traveled" linearly with time (constant physical
   speed) and looks up world position + tangent from this table each tick —
   NOT by advancing the raw spline parameter directly, which would speed up
   through curves and crawl on straightaways. This is Premise 1's explicit,
   already-decided requirement from the eng review, not new judgment.

3. **Look-at beats.** Authored points along the rail (each keyed by distance)
   that the camera's look-at target interpolates toward/between, independent
   of the ground-plane forward direction — this is what gives the camera
   authored "moments" rather than always looking straight down the spline
   tangent.

4. **Real 3D perspective + look-at rendering.** Reintroduce `make_perspective`
   and `make_look_at` matrix functions in `RexRenderer` (or equivalent). The
   world (ground plane now, targets, later dinos) renders through a real 3D
   camera transform derived from the rail camera's position/look-at, replacing
   M1's manual perspective-divide hack. **The 2D screen-space reticle and the
   debug HUD stay screen-space** (Premise 2 — aim never touches the 3D camera)
   — this means TWO render passes/projections coexist: a 3D perspective pass
   for world geometry, and the existing 2D ortho pass layered on top for
   reticle/HUD. Do not collapse these into one.

5. **M1's test-scene targets must keep working end to end.** They currently
   fake their screen position from the old dolly's `dollyZ`. Re-anchor them as
   real 3D world-space objects (still simple placeholder boxes — no real dino
   assets, that's M3) positioned along/near the rail, and project them to
   screen space through the new real camera matrices for hit-testing —
   don't leave them on the old fake-perspective math while the camera itself
   moves on the new spline. This is the integration point most likely to be
   silently skipped; call it out explicitly if anything from M1's test scene
   needs to change to keep working.

6. **JSON chart format.** A file (e.g. `assets/charts/m2-test.json` or
   similar — pick a sensible location under `assets/`, which already exists
   as a bundled-resources folder) containing: the rail's control points,
   look-at beats (each keyed by distance), and a generic `events` array keyed
   by distance (event *type* handling beyond "exists and is stored" is a
   later milestone's job — M2 just needs to parse and hold onto them, not
   act on them). Loaded once at launch (no file-watcher/hot-reload — that's
   an explicitly deferred comfort feature per the design doc).

7. **Malformed/missing chart fails loudly**, per the design doc's Failure
   Modes review — no silent empty level.

## Explicitly out of scope (do not build)

- Dino assets, Quaternius integration, animation generalization — M3.
- Scoring, health, weak-point hit-testing semantics beyond "can a screen
  point be tested against a target's screen bounds" (which already exists
  from M1) — M4a.
- Determinism/replay harness changes beyond what already exists — M4b.
- Chart hot-reload/file-watching — explicitly deferred, launch-time load only.
- Any change to `ReticleSystem`'s aim model, fallback-assist tuning, or the
  gyro input path — none of that is in scope here. If something about the
  camera change seems to require touching `ReticleSystem_update`'s aim math
  itself (not just how targets get their screen position), stop and flag it
  rather than proceeding — Premise 2 is settled and shouldn't need revisiting
  for a camera-only milestone.

## Acceptance criteria

- `xcodegen && xcodebuild -scheme Rex-macOS -derivedDataPath .build/DerivedData build` succeeds.
- `xcodegen && xcodebuild -scheme Rex-tvOS -destination 'generic/platform=tvOS' -derivedDataPath .build/DerivedData build` succeeds.
- A test chart JSON file exists with at least one curved (non-straight)
  section, loaded at launch, driving the rail camera.
- `RexLogicTests` gains (per the design doc's own Test Plan section, which
  already names these):
  - `RailCameraTests.mm`: constant-speed travel through a curve — equal
    time-ticks produce equal *arc-length* delta, demonstrably NOT equal
    raw-spline-parameter delta (the test should be able to tell the
    difference, e.g. by asserting behavior that would fail under naive
    t-parameterization). Also: look-at target updates correctly at authored
    beats.
  - `ChartLoaderTests.mm`: a known JSON fixture parses to the expected rail
    control points, look-at beats, and event list at expected distances
    (round-trip test). A missing/malformed chart fails loudly (assert/error),
    not silently producing an empty level.
- M1's existing test scene (pop-up targets + one moving target) still renders
  and is still hit-testable via the reticle, now driven by the real spline
  camera instead of the placeholder dolly. Existing `ReticleInputTests.mm`
  tests must still pass unmodified in behavior (their assertions may need
  updating only if the target/camera data shape changed in ways that break
  compilation, not because the aim model itself changed).
- All prior tests (`WorldSmokeTests.mm`, `ReticleInputTests.mm`) still pass.
- Launched on macOS: the ground plane and targets now render with real
  perspective (things farther down the rail look smaller, the view genuinely
  changes as the camera turns through a curve) — not just a 2D top-down feel.

## Verification (Claude, after the task)

```sh
cd ~/workspace/MetalRex
xcodegen
xcodebuild -scheme Rex-macOS -derivedDataPath .build/DerivedData build -quiet
xcodebuild -scheme Rex-tvOS -destination 'generic/platform=tvOS' -derivedDataPath .build/DerivedData build -quiet
xcodebuild -scheme RexLogicTests -destination 'platform=macOS' -derivedDataPath .build/DerivedData test
scripts/run.sh   # eyeball: real 3D perspective, camera moves through a curve, reticle/HUD still overlay correctly
```

## Out of scope for M2 (next milestones)

Dinos + animation generalization (M3), scoring/health (M4a), determinism/replay
(M4b), Act 1 content + 2P join (M5a/M5b). See DESIGN.md's Next Steps.
