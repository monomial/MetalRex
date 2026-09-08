# Plan — Name the three clocks, then make scenarios cheap to write

Workflow contract: same as prior passes (see PLAN-M1.md) — Claude plans,
Codex implements.

Design reference: [PLAN-M4b-DETERMINISM.md](PLAN-M4b-DETERMINISM.md), which
landed the record/replay harness this plan both *uses* (Decision 1's proof)
and *builds on* (Decisions 2-3).

Two halves. Decision 1 is a pure rename whose whole point is that the new
harness can prove it changed nothing. Decisions 2-6 attack the reason adding
a test is currently expensive.

---

# Part 1 — The three clocks

## Why

The sim has three distinct notions of elapsed time, and the parameter names
disagree with reality in five of ten systems. This is not cosmetic: it is
exactly the confusion that produced the wrong gyro analysis in the M4b draft
(see f5ae0bf), where `gameDt` was read as "some variable frame delta" when it
is always a constant.

| clock | what it is | who sees it |
|---|---|---|
| **physical** | wallclock since last frame, variable, clamped to 0.1s | `World::update`, `ParticleSim` |
| **game** | the fixed tick, **always** `kFixedDt` = 1/120, real/player time | Reticle, BossMajorAttack, Scoring, ScreenShake, PlayerHealth |
| **world** | game time scaled by `kMajorAttackSlowMoScale` during a boss QTE | RailCamera, Arena, DinoBehavior, Animation |

The mismatches, all verified:

- `RailCameraSystem`, `ArenaSystem`, `DinoBehaviorSystem`, `AnimationSystem`
  each declare `float gameDt` but are called with `worldDt`
  (`World.mm:535-548`). Inside those four files the identifier `gameDt`
  holds world time.
- `ScreenShakeSystem_update` declares `float physicalDt` but is called with
  `gameDt` (`World.mm:482`), and uses it as a per-tick decay. Wrong in the
  opposite direction.
- `World::update(float physicalDt, float gameDt)` — the second parameter is
  **unused** (`/*gameDt*/` in the definition, `World.mm:573`) and the host
  calls `update(dt, dt)`. It implies a distinction that does not exist there.

## Decision 1 — Rename to match reality; change no behaviour

1. Rename the parameter to `worldDt` in the four world-time systems — header,
   definition, **and every use inside the function body**. This is the bulk of
   the change and the only place to be careful.
2. Rename `ScreenShakeSystem_update`'s parameter to `gameDt`.
3. Drop `World::update`'s dead second parameter -> `void update(float physicalDt)`,
   and update the host call site to `_world->update(dt)`.
4. Add a short comment block above `World::tick` stating the table above —
   specifically that `gameDt` is always exactly `kFixedDt`, and that `worldDt`
   is the only one slow-motion touches.

**Acceptance is mechanical and non-negotiable:** record a wave, then replay it
across the rename and assert a **byte-identical score timeline**. The M4b
harness exists precisely so a change like this is provable rather than
argued. If the timeline moves, the rename touched something real — stop and
report rather than adjusting the expectation.

Do **not** rename `gameDt` to something else in the five systems that really
do receive game time. The name is correct there; only the liars change.

---

# Part 2 — Make scenarios cheap

## Why

Adding a gameplay test currently costs ~25 lines of chart surgery before a
single assertion. From `ReplayTests.mm`: load `m2-test.json`, walk `events`
to find the wave whose label is `pack-test`, rewrite its `distance` to 0,
shove `boss.arrivalDistance` to 1000 so the boss stays away, re-serialize
with sorted keys, write a temp fixture, load that. Every future test that
wants "one pack wave and nothing else" pays that cost again.

Driving input is worse: there is no way to author an input stream at all.
`REX_RECORD` captures a human session, and tests hand-poke `set_input` per
tick. So a scenario like "fire inside the interrupt window on the second
raptor" cannot be written without either a human recording it or bespoke
per-tick loops.

The sim is now deterministic and replayable. That is the hard part, and it
is done. What is missing is ergonomics.

## Decision 2 — A scenario builder

Add `RexLogicTests/ScenarioBuilder.{h,mm}` (test-target only; this is test
infrastructure, not engine code) wrapping the chart surgery:

```objc
LevelChart chart = Scenario()
    .onlyWave(@"pack-test")      // keep one labelled wave, move it to distance 0
    .noBoss()                    // arrivalDistance = 1000
    .noArena()                   // arenaWaveCount = 0
    .build();                    // serializes + loads, temp file cleaned up
```

Requirements:

- Preserve M4b's chart-identity contract: the builder must write real bytes
  and load them, so the chart hash in a replay header stays honest. Do not
  bypass `ChartLoader` or synthesize a `LevelChart` in memory.
- Sorted-key serialization (as the existing code does), so the same scenario
  hashes identically across runs.
- Then **rewrite `ReplayTests.mm`'s `waveChart` to use it**, as the proof it
  covers the real case.

## Decision 3 — Scripted input, so scenarios need no human

Add `ScriptedInput` (test-target) that produces an `InputRecording` from
declarative steps, so a scenario is authored rather than performed:

```objc
ScriptedInput script(/*players*/1);
script.wait(Ticks(120));
script.aimAt(/*targetIndex*/0);       // sets reticle via stick/gyro toward the target
script.fireAt(FirstTickWhere(interruptWindowOpen));
script.run(world, /*maxTicks*/2000);
```

Design notes that matter:

- `FirstTickWhere(...)` needs a predicate evaluated against live `World`
  state each tick. Keep the predicate set small and concrete to start:
  interrupt-window-open for a given dino, a dino reaching a given state, a
  tick index. Do not build a general expression language.
- `aimAt` must drive the reticle through the **normal input path** (stick or
  gyro deltas), never by writing `reticle.x/y` directly. A test that
  teleports the reticle stops testing hit-testing and aim entirely.
- The produced `InputRecording` must be savable, so a scripted scenario can
  be exported and replayed in the real renderer via `REX_REPLAY` for eyeball
  checks. This is the bridge between the headless suite and visual review.

## Decision 4 — Invariants over a deterministic sim

With determinism landed, invariant tests get cheap and catch whole classes of
bug. Add `RexLogicTests/InvariantTests.mm` that runs several scenarios (and a
fuzz stream of pseudo-random but **seeded** inputs) asserting, every tick:

- No NaN or infinity in any reticle position, target screen position, world
  position, or health value.
- `0 <= playerHealth <= max`; a `sittingOut` player never takes further damage.
- Every dino that becomes `activeInEncounter` eventually reaches `Dormant`,
  `PutDown` or `Departing` within a bounded tick budget — nothing gets stuck
  mid-cycle. (This is the class of bug the `interruptWindowOpen` lifecycle
  and the `tellCueFired` latch could both have introduced.)
- No dino enters `Attack` without having passed through `Tell`.
- `currentStreak` and every score counter are non-negative and monotonic
  where they should be.
- Audio cue tallies are drained to zero every frame — no unbounded growth.

Fuzzing input is safe here precisely because the sim is deterministic: a
failure reproduces exactly from its seed, and the harness can dump the
offending `InputRecording` on failure. **Make it dump that file** — a fuzz
failure you cannot replay is a bug report with no repro.

## Decision 5 — Close the loaded-asset CI gap

`ClipDurationTests`' loaded-asset check skips without a Metal device, so CI
never verifies the authoritative table against the real assets — the exact
drift M4b just fixed could silently return.

Read the frame counts from the `.usdz` files **without** a Metal device
(ModelIO asset metadata: `startTimeCode`/`endTimeCode`/`timeCodesPerSecond`,
then the loader's own `ceil(dur * 30) + 1`), and assert the table matches.
If that proves impossible headless, generate a small committed JSON manifest
of measured frame counts as a build step and assert against that instead —
but try the direct read first, since a manifest is one more thing to go stale.

The test must **fail**, not skip, when the table and the assets disagree.

## Decision 6 — Capture contact sheets, not pixel goldens

`--capture-out=` / `--capture-after=` / `--auto-fire` already exist and
`fixedFrameDt` makes the drive deterministic. What is missing is using them
systematically.

Add `scripts/capture-scenes.sh` that drives the app through a fixed list of
named moments (title, mid-wave, interrupt window open, weak-point visible,
boss QTE popup, arena holdout, grade screen) at fixed tick counts, writing
PNGs to a gitignored directory, and assembles a contact sheet.

**Explicitly do not gate CI on pixel equality.** Golden-image comparison
across GPUs, drivers and OS versions is a maintenance sink that produces
false failures; the runner is not this Mac. The value here is a human
scanning one sheet after a visual change, plus cheap structural assertions
(the file exists, is the expected dimensions, is not uniformly one colour —
which catches a black frame or a failed draw).

---

## Implementation order

1. Decision 1 (rename) — first and alone, with the byte-identical-timeline
   proof. Landing it separately keeps the diff readable.
2. Decision 2 (scenario builder) + rewrite `ReplayTests.mm` onto it.
3. Decision 3 (scripted input).
4. Decision 4 (invariants + seeded fuzz).
5. Decision 5 (asset-table CI gap).
6. Decision 6 (capture script).

## Test plan

- Decision 1: record -> replay across the rename, byte-identical timeline;
  full suite green with no assertion edits.
- Decision 2: a scenario built by the builder produces the same chart hash on
  two runs, and `ReplayTests` passes unchanged in behaviour after being
  rewritten onto it.
- Decision 3: a scripted "fire inside the interrupt window" scenario yields
  exactly one `InterruptSuccess` and zero player damage; the same script
  exported and replayed reproduces its timeline.
- Decision 4: invariants hold across every named scenario and a seeded fuzz
  run; deliberately breaking one (temporarily) makes the test fail with the
  offending tick and a dumped recording path.
- Decision 5: the asset check runs (not skips) headlessly and fails on a
  deliberately corrupted table value.
- Decision 6: the script produces the expected file set; each is non-empty
  and not a single flat colour.

Then `scripts/smoke.sh --autotest` and `scripts/smoke.sh`, `REX_MUTE=1` for
manual runs. Report sandbox blocks plainly rather than claiming green.

## Explicitly out of scope

- **Pixel-exact golden images in CI.** See Decision 6.
- **A general scenario DSL or expression language.** Concrete predicates only.
- Any gameplay constant change, including `kTellLeadSeconds` and
  `interruptEndNormalized`.
- Renaming `gameDt` in the five systems that legitimately receive game time.
- New encounters, species, audio, or UI.
- Replacing XCTest, or adding a third-party test framework.
