# Plan — M4b: determinism and the replay harness

Workflow contract: same as M0-M4a, the encounter-feel pass, the audio tell and
the legibility pass (see PLAN-M1.md) — Claude plans, Codex implements.

Design reference: [DESIGN.md](DESIGN.md) Next Steps item 6 (M4b), Premise 7
(deterministic sim -> score-verification replays), and [TODOS.md](TODOS.md)
item 5, which warned before M1 that deferring determinism turns it into
archaeology. This is that archaeology, and the survey below is the dig.

## Why this pass exists

The stated goal is that **the whole game is deterministic**: same inputs, same
outputs, every time, on any machine, at any frame rate.

The good news from the survey is that the foundation is sound and most of the
hard discipline is already in place. The bad news is five specific leaks, two
of which are live gameplay bugs today, not merely replay obstacles.

## Ground truth: what is already deterministic (do NOT "fix" these)

Verified by reading, not assumed. Leave all of it alone:

- **`World::tick` is strictly fixed-dt.** `World::update` accumulates
  `physicalDt` and runs `tick(kFixedDt)` in a `while` loop; every system
  inside takes `gameDt`/`worldDt` derived from that constant. Variable frame
  time never reaches a system.
- **Sim RNG is one seeded xorshift.** Every draw goes through
  `World::rand_float01()`. There is no `rand()`, `drand48()`, `arc4random()`,
  `std::mt19937` or `random_device` anywhere under `RexEngine/Simulation`.
- **`ScreenShakeSystem_update` already draws exactly one RNG value per tick
  unconditionally**, with a comment explaining that conditional consumption
  would let shake state shift another seeded World's stream. That reasoning is
  correct and this pass depends on it. Preserve the unconditional draw.
- **Wallclock never enters the sim.** `CACurrentMediaTime()` appears only in
  `RexGameHost`, the frame driver.

## The five leaks

### 1. Input is captured per frame but consumed per tick

`RexGameHost::advanceFrame` calls `set_input` once, then `World::update` runs
however many fixed ticks the accumulator owes. Every tick in that frame reads
the *same* `_inputs[p]`. A frame that runs 3 ticks applies one sample 3 times;
at a different frame rate the same physical motion lands on a different number
of ticks. This is the central reason a naive "record what the shell sent"
replay would not reproduce.

### 2. Gyro is a raw per-tick delta, and is frame-rate coupled (a live bug)

The shells sample `motion.rotationRate` once per frame and pre-scale it by a
hardcoded `1.0 / 120.0` (`Rex-tvOS/GameViewController.mm:204-205`, macOS
equivalent), as if a frame were a tick. `ReticleSystem.mm:133-134` then
applies it with **no `gameDt`**:

```cpp
dx += gyroX * s_tuning.gyroSensitivityH;   // stick above it is * gameDt; this is not
```

So the reticle trajectory depends on how ticks land inside frames. The
long-run average survives (the accumulator still runs 120 ticks/second), but
*which* samples get applied twice differs with frame rate — and the stillness
smoothing (`smooth_toward`) is a stateful IIR filter, so tick alignment
compounds into a different path, not just different noise. On a 120Hz ProMotion
Mac versus a 60Hz Apple TV, the same wrist motion aims differently today.

### 3. `ReticleTuning` is a mutable global that decides scoring

`ReticleSystem.mm:6` is a file-scope `static ReticleTuning s_tuning`, adjusted
live by the debug HUD. It sets sensitivity, smoothing, stillness threshold and
fallback magnetism — i.e. exactly where the reticle goes, hence what gets hit,
hence the score. A replay that does not restore it reproduces nothing.

### 4. Clip durations are ambient global state, and headless disagrees with the game

`AnimationSystem.mm:6-8` holds `s_dinoChars[]` as process globals, and
`clip_duration` falls back to `kClipDurationFallback` when assets are not
loaded. The fallback is **stale and wrong**: its own comment describes
MetalBrawler's Mixamo clips, not MetalRex's Quaternius dinos.

| clip | fallback (headless) | real velociraptor (baked) |
|---|---|---|
| Idle | 3.83s | 2.533s |
| Walk | 1.03s | 2.467s |
| Run | 0.80s | 0.600s |
| **Attack** | **1.03s** | **0.867s** |
| Jump | 0.70s | 1.167s |
| Death | 4.50s | 1.333s |

Attack duration drives `attack_progress`, so it sets the interrupt window and
feeds the derived-health computation. **The 95 logic tests are currently
validating a 172ms interrupt window while the shipped game runs 145ms.** Same
input log, same code, two different games. This must be closed before a replay
assertion means anything.

(Real values are `frameCount / 30` from the `CharacterLoader` log of a real
run — 26 frames for the raptor attack. Note the log's own printed seconds is
the *source* duration, not the baked one the sim uses.)

### 5. Shake state is process-global, shared across `World` instances

`ScreenShakeSystem.mm:7-8` keeps `s_magnitude` and `s_offset` at file scope.
Two `World`s in one process share them. It is cosmetic (the renderer reads the
offset; no sim state depends on it), but the determinism tests construct two
seeded worlds in one process, so it is a cross-contamination hazard sitting
directly under the harness this plan builds.

---

## Decision 1 — Port `InputRecording`, and capture at the tick seam

Port `MetalMoto/MotoEngine/Simulation/InputRecording.{h,mm}` (a 4-method class,
~90 lines) into `RexEngine/Simulation/`. Mechanical changes only:

- Field list becomes MetalRex's `InputState`: `stickX`, `stickY`,
  `gyroDeltaX`, `gyroDeltaY`, `recenter`, `fire`, `pause`.
- Header string becomes `metalrex_replay_v1`.
- Keep the text format and `std::setprecision(9)` — 9 significant digits
  round-trips a `float` exactly, which is the property the whole harness rests
  on. Do not switch to a binary format for "efficiency"; a diffable replay is
  worth far more here.

**Capture inside `World::tick`, not in `RexGameHost`.** At the top of `tick`,
append the current `_inputs[]` row to the active recording. That is the only
seam where "one row = one tick" is true by construction, and it makes leak 1
structurally impossible to reintroduce.

Add to `World`:

```cpp
void begin_recording(uint8_t playerCount);
void begin_replay(const InputRecording& log);   // drives _inputs from the log
const InputRecording* recording() const;
bool replay_finished() const;
```

During replay, `tick` populates `_inputs[]` from the log by tick index and
**ignores `set_input`** entirely, so a live controller cannot perturb a replay.

## Decision 2 — Latch gyro into the tick

Fix leak 2 at the seam, and fix the live bug at the same time.

The shells stop pre-scaling by `1.0/120.0` and instead pass the **raw
`rotationRate`** (radians/sec) in `gyroDeltaX/Y`. Rename the fields to
`gyroRateX`/`gyroRateY` so the units are not a lie. `ReticleSystem` then
consumes them as a rate:

```cpp
dx += gyroX * s_tuning.gyroSensitivityH * gameDt;   // now matches the stick path
```

This makes gyro aim frame-rate independent — the same wrist motion produces
the same reticle travel at 60Hz or 120Hz — and it makes a per-tick recorded
value meaningful rather than an artifact of frame pacing.

**This changes aim feel.** `gyroSensitivityH/V` currently absorb the implicit
`1/120`, so the raw numbers must be rescaled by ~120x to preserve today's
feel. Compute the equivalent defaults, keep the clamp ranges proportional, and
say plainly in the commit that gyro sensitivity constants moved and why.

> If a rescale that preserves feel cannot be derived confidently, stop and say
> so rather than shipping a silent sensitivity change. This is the one place
> in this plan where getting it wrong is felt immediately by the player.

## Decision 3 — The header carries everything that is not input

A replay is only reproducible if the non-input state matches. Extend the
header beyond MetalMoto's `version / playerCount / tickCount` with:

- **RNG seed** — the value `World` was seeded with.
- **Chart identity** — the chart name plus a cheap hash of its bytes, so an
  edited chart invalidates old replays instead of silently diverging.
- **The full `ReticleTuning` struct** (leak 3).
- **The clip-duration table actually in effect** (leak 4).
- `kFixedDt`, and the tuning constants the sim keys off:
  `kAttackClipSpeedMultiplier`, `interruptStart/EndNormalized`,
  `tellEndNormalized`, `kTellLeadSeconds`, `kHealthPerWindowSecond`.

On load, compare every field against the live build. **Mismatch fails loudly
with the specific field named** — never a silent best-effort replay. A replay
that cannot reproduce must say which knob moved; that error message is the
harness's most useful output, because it is what will fire the next time
someone retunes the interrupt window and wonders why old replays broke.

## Decision 4 — One clip-duration table, per species

Close leak 4 so headless and loaded agree.

Replace the single stale `kClipDurationFallback` with a **per-species** table
carrying the measured baked durations (`frameCount / 30`), velociraptor and
trex at minimum, since those are the two species in play. Then:

- Add a startup check comparing each loaded character's real baked durations
  against the table and logging loudly on any mismatch beyond a small epsilon.
  The table is a claim about the assets; make the assets police it.
- Record the effective table in the replay header (Decision 3).

The immediate payoff is independent of replay: **the logic tests start
validating the timings the game actually runs.** Expect some existing timing
assertions to shift when Attack moves 1.03s -> 0.867s — that is the bug being
fixed, not a regression. Update those assertions and call it out explicitly in
the report.

## Decision 5 — De-globalize shake state

Move `s_magnitude` and `s_offset` into `World` as ordinary members, with
`ScreenShakeSystem_offset(const World&)` reading from there. Keep the
unconditional per-tick RNG draw exactly as it is.

Small change, but it removes the last piece of cross-`World` mutable state
sitting under a harness whose whole job is comparing two `World`s.

## Decision 6 — The verification harness

A replay that only checks a final score number is nearly useless — it tells
you *that* something diverged, never *when*. Assert a **timeline**.

Add a score-timeline capture: for each tick that produced any `DinoScoreEvent`,
record `(tickIndex, player, event, species)`. Then:

```
record: run N ticks with scripted inputs -> log + timeline A
replay: fresh World, same seed, same log -> timeline B
assert: A == B, and on mismatch report the FIRST differing tick index
```

Wire it as `RexLogicTests/ReplayTests.mm` (headless, runs in CI), and add a
`REX_REPLAY=<path>` env hook to the app alongside the existing
`REX_CAPTURE_ARENA` / `REX_CAPTURE_PLAY` hooks, so a recorded session can be
played back in the real renderer for eyeball verification.

Also add `REX_RECORD=<path>` to write a log from a live session. A replay
harness nobody can produce input for is a harness nobody uses.

---

## Implementation order

Each step builds green independently. Do them in this order — 4 before 6, or
the harness will be asserting against the wrong timings.

1. Decision 5 (shake de-globalization) — smallest, isolated, removes a hazard
   the later tests sit on.
2. Decision 4 (clip-duration table + startup check + assertion updates).
3. Decision 1 (`InputRecording` port + tick-seam capture/replay).
4. Decision 3 (header fields + loud mismatch errors).
5. Decision 6 (timeline capture + `ReplayTests.mm` + env hooks).
6. Decision 2 (gyro latch + sensitivity rescale) — last, because it is the
   only step that changes feel, and doing it last means the harness built in
   steps 1-5 can prove it changed nothing else.

## Test plan

`RexLogicTests/ReplayTests.mm`, plus additions to the existing suites:

- Round-trip: `appendTick` x N -> `saveToFile` -> `loadFromFile` yields
  bit-identical `InputState` values for every tick and player (this is what
  `setprecision(9)` buys; assert exact equality, not epsilon).
- Record-then-replay over a full wave produces identical score timelines, and
  identical final `_tickCount`, score, streak and player health.
- A replay whose header names a different seed / chart hash / tuning value
  **fails with that field named**, and does not run.
- Replay ignores `set_input`: injecting live input mid-replay changes nothing.
- Two `World`s replaying the same log in one process produce identical
  timelines (this is the leak-5 regression test).
- Frame-rate independence: driving `World::update` with a ragged `physicalDt`
  sequence (e.g. alternating 1/60 and 1/144, plus one long hitch) produces the
  same per-tick timeline as a uniform 1/120 drive, for the same tick count.
- Gyro: a fixed rotation rate applied over one second of ticks produces the
  same total reticle displacement regardless of the `physicalDt` pattern
  (the leak-2 regression test).
- Clip table: the per-species table matches the loaded assets' baked durations
  within epsilon, asserted in a test rather than only logged.

Then `scripts/smoke.sh --autotest` and `scripts/smoke.sh`. Use `REX_MUTE=1`
for any manual run. Both smoke scripts may fail in a sandbox on code signing
or `testmanagerd` — if so, report that plainly rather than claiming green, and
say which checks did and did not run.

## Explicitly out of scope

- **Rendering determinism.** Particles, score popups and shake offset are
  cosmetic and frame-rate driven by design. Only the *sim* must be
  deterministic; do not try to lock the renderer to the tick.
- **Cross-platform bit-exactness.** Same binary, same machine is the bar here.
  Cross-architecture float reproducibility (fast-math, FMA contraction,
  libm differences) is a much larger question — note anything suspicious, but
  do not chase it or start adding `-ffp-contract` flags.
- **Replay compression, seeking, or a scrubbing UI.** Text logs, played from
  the start.
- **Retuning any gameplay constant** beyond the gyro sensitivity rescale that
  Decision 2 forces. In particular `kTellLeadSeconds` and
  `interruptEndNormalized` stay where they are; they are still unfelt.
- **Networked or shared replays**, score verification as an anti-cheat
  feature, and ghost playback.
