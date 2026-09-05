# Plan — Audio Slice 1: the attack tell

Workflow contract: same as M0-M4a and the encounter-feel pass (see PLAN-M1.md)
— Claude plans, Codex implements. No new asset pipeline; one synthetic
fallback plus an optional bundle file drop.

Design reference: [DESIGN.md](DESIGN.md) "What Makes This Cool" (reading the
animal IS the scoring system), Premise 2, and [TODOS.md](TODOS.md) items 5
(determinism) and 6 (audio as a core feel system).

## Why this slice exists

The game has exactly two audio call sites in the entire codebase:

```
RexGameHost.mm:108   playFireSound      (one per shot)
RexGameHost.mm:173   startBattleMusic
```

Rumble is identical — `ControllerRumble.playShootPulse`, one pulse per shot.
Both output channels are driven purely by the player pulling the trigger.
Everything the world does — a raptor arriving, tensing, striking for 15 —
happens in silence.

**Hit confirmation is deliberately NOT the fix and is not in this plan.** It
was removed on purpose (see the comment at `RexGameHost.mm:101`) because the
arcade game this clones does not have one. That call stands. The reference is
the filter for every cue below.

What the reference *does* have, and what this slice adds, is the animal
telling you it is about to strike. That is not polish: `ScoringSystem` pays
50 for an interrupt-window put-down versus 10 for a body shot, so reading the
tell is the scoring identity. Today the tell has **no signal at all** — a
grep for tell handling in `RexRenderer.mm` finds nothing but a rage-tint
comment. The only cue is the attack clip starting, which is unreadable for an
animal that is off-centre, occluded, or one of three in a `pack-test` wave.

## Ground truth: the tell is too short to hold a lead cue

This is the finding that shapes the whole design, so verify it first.

`enter_attack` (`DinoBehaviorSystem.mm:66`) sets `state = Tell` and requests
the Attack clip. From there:

- `attack_progress` = `anim.clipTime / clip_duration(Attack)`.
- `clipTime` advances at `gameDt * kAttackClipSpeedMultiplier * rateScale`,
  where `kAttackClipSpeedMultiplier` is **4.0** (`Components.h:8`) and
  `rateScale` is the per-entity ±12% from the encounter-feel pass.
- `Tell` ends at `tellEndNormalized` 0.28; the interrupt window is
  [`interruptStartNormalized` 0.18, `interruptEndNormalized` 0.46]; the strike
  lands when the clip completes (progress 1.0).

The encounter-feel calibration (default chase window ≈ 4.6s, of which
approach ≈ 2.38s and hold 2.0s) leaves `tellTime` ≈ 0.22s, and since
`tellTime = interruptEndNormalized * duration / 4.0`, the raw Attack clip is
≈ 1.9s — about **0.48s of real time from tell to strike, with a ≈134ms
interrupt window**.

So "fire the cue 0.4s before the strike" cannot be done inside `Tell`: the
entire state is shorter than the lead. Placing it there would also make the
lead vary per species (clip duration) and per entity (`rateScale`).

> **Step 0 for the implementer:** the 1.9s above is derived from the plan
> doc's arithmetic, not measured. Log the real
> `AnimationSystem_clip_duration(world, id, CharacterClipSlot::Attack)` for
> the velociraptor once and record it in this doc. If it differs materially,
> the placement below still holds — only the prose numbers change.

**Therefore the cue fires during `Hold`, at a fixed lead before the lunge**,
where the transition instant is exactly known and independent of clip data:
`dino.stateTime >= dino.holdDuration + dino.attackDelay` (`Hold` case,
`DinoBehaviorSystem.mm`). The animal vocalises, *then* lunges — which is both
the genre convention and the only placement that gives a learnable lead.

## What already exists (do not rebuild)

- `AudioEngine` (`RexEngine/Audio/`), inherited from MetalBrawler: 8
  `AVAudioPlayerNode` voices round-robined by `_playBuffer`, synthetic
  fallback buffers, and bundle-file override by name (`sfx_<name>` in
  `.wav/.caf/.mp3/.m4a`). Capable and unused — all 9 of its SFX methods
  except `playFireSound` are dead brawler vocabulary (`playSwing`,
  `playDodge`, `playFinisher`, `playRoomClear`).
- `REX_MUTE` correctly gates everything: `startupInit` returns before
  `_started` is set, so `_playBuffer` no-ops. Test runs stay silent.
- `REX_AUDIO_LOG=1` timestamps every SFX (`AudioEngine.mm:333`) — use it to
  verify cue timing without listening.
- The frame-buffered cue contract: `World::audio_cues()` accumulates,
  `World::consume_audio_cues()` drains and resets, `RexGameHost` plays.
- `World::rand_float01()` — deterministic xorshift, for any jitter below.

---

## Decision 1 — Fire in `Hold`, once, at a fixed lead

Add to `DinoBehaviorComponent` (`Components.h`):

```cpp
// Pre-lunge vocalisation: set once when the tell cue is emitted during Hold,
// cleared on every state entry that can lead to a fresh attack cycle.
bool tellCueFired = false;
```

and a new constant beside the other tuning values:

```cpp
static constexpr float kTellLeadSeconds = 0.45f;
```

In the `Hold` case, before the existing transition check:

```cpp
float leadPoint = dino.holdDuration + dino.attackDelay - kTellLeadSeconds;
if (!dino.tellCueFired && !dino.isBoss && dino.stateTime >= std::max(0.f, leadPoint)) {
    world.audio_cues().raptorTells += 1;
    dino.tellCueFired = true;
}
```

Notes that matter:

- **`std::max(0.f, leadPoint)` is the short-hold clamp, not a nicety.** A
  `close_ambush` runs `holdScale` 0.45, and arena spawns pass an explicit
  `holdSeconds` through `DinoBehaviorSystem_spawn_arena_raptor`. When the
  hold is shorter than the lead, the cue must fire immediately on entering
  `Hold` — still exactly once — rather than being skipped. A silent lunge is
  the failure this slice exists to remove.
- **The boss is excluded** by the same `!dino.isBoss` test that already gates
  `enter_attack`: the boss never melees (it looms in `Hold` and attacks only
  through the scripted QTE), so it would otherwise emit a tell for a lunge
  that never comes. Boss audio is its own slice.
- **Arena raptors are included** — they run the same state machine, and the
  holdout is exactly where overlapping threats are hardest to read.
- Clear `tellCueFired = false` in `enter_dormant`, `enter_approach`, and
  `enter_hold` (the arena/boss re-approach loop returns through `Hold`, so
  clearing only on activation would give each arena raptor one tell for its
  whole life).
- The lead is in **game** seconds, so it stretches automatically under
  `kMajorAttackSlowMoScale` during a QTE. That is correct and intended.

## Decision 2 — Cue plumbing, and one doc correction

Extend the tally in `World.h:22`:

```cpp
struct AudioCueCounts {
    int shotsFired  = 0;
    int raptorTells = 0;  // pre-lunge vocalisation, emitted during Hold
};
```

Drain in `RexGameHost::_playAudioCues`:

```cpp
// A three-raptor wave can tell on the same tick; more than two identical
// buffers layered combs rather than reads as more animals.
int tells = std::min(cues.raptorTells, 2);
for (int i = 0; i < tells; ++i) [_audio playRaptorTellSound];
```

The sim emits the truthful per-dino count; the **host** clamps for mix
hygiene. Keeping the clamp out of the sim leaves the count assertable in
tests and keeps the sim free of presentation policy.

**Correct a stale comment while here.** `AudioEngine.h` claims SFX are "safe
to call every frame, internally rate-limited". They are not — `_playBuffer`
round-robins 8 nodes with no rate limiting whatsoever. Fix the comment to say
callers are responsible for their own limiting. It is a one-line change and
the next person to trust that sentence will layer 8 voices.

## Decision 3 — One species now, species-keyed later

Only the velociraptor ever reaches `Tell` today: the boss does not melee, and
no other species is spawned. So the per-species question is moot for this
slice — ship one cue.

Add to `AudioEngine`, alongside the existing methods:

```objc
- (void)playRaptorTellSound; // pre-lunge screech; see sfx_raptor_tell
```

backed by `_raptorTellBuf`, loaded via the existing
`loadBundleBuffer(@"sfx_raptor_tell", fmt)` override path with a synthetic
fallback (Decision 4). When a second melee species arrives (triceratops
charge, TODOS #12), this becomes `playTellSoundForSpecies:` and the archetype
table gains a per-species file name — a rename plus a switch, not a redesign.
Do not build that generality now.

## Decision 4 — Synthetic fallback so it is never silent

Every other cue in `AudioEngine` has a synthetic fallback, which is why the
game makes sound with only three files on disk. Match that: write
`make_raptor_tell_buffer(fmt)` next to the others — a short (~0.35s) rising
screech, e.g. a sawtooth-ish sweep from roughly 400Hz to 1.1kHz with a fast
attack, a band-passed noise layer for rasp, and an exponential decay.

Tune it to sit *above* the music bed and clearly apart from `make_fire_buffer`
(a broadband crack) so it is not mistaken for a shot.

`rand()` in these synth builders is fine and does not violate TODOS #5: the
buffers are built once at startup on the audio side and never touch sim
state. Leave a one-line comment saying so, since the surrounding discipline
says otherwise.

## Decision 5 — Bundle wiring: a file drop is enough (verified)

No target edit is needed. `project.yml` mounts `assets` as a folder reference
with `buildPhase: resources` on all three targets (Rex-macOS, Rex-tvOS,
RexLogicTests), and `bundleAudioURL` (`AudioEngine.mm:182`) already searches
`""`, `assets/audio` and `audio` across five extensions. Dropping
`sfx_raptor_tell.wav` into `assets/audio/` overrides the synthetic on every
target with no `project.yml` change.

---

## Implementation order

1. Step 0 — measure and record the real Attack clip duration.
2. Decision 2 plumbing (`AudioCueCounts.raptorTells`, host drain, header
   comment fix) — inert until something emits.
3. Decision 4 synthetic buffer + Decision 3 method, verified with
   `REX_AUDIO_LOG=1`.
4. Decision 1 emit site + `tellCueFired` lifecycle.
5. Tuning pass on `kTellLeadSeconds` against a `pack-test` wave.

## Test plan

Extend `RexLogicTests/DinoBehaviorTests.mm` (and add cue assertions where
they fit naturally):

- A full activate → `Hold` → `Tell` → strike cycle emits **exactly one**
  `raptorTells`, not one per tick.
- The cue lands within one tick of `kTellLeadSeconds` before the state leaves
  `Hold`.
- A spawn whose `holdDuration + attackDelay < kTellLeadSeconds` (the arena /
  `close_ambush` path) still emits exactly one, on the first `Hold` tick.
- The boss emits **zero** `raptorTells` across an arrival → loom span.
- An arena raptor that survives a retreat and re-approaches emits a **new**
  cue on its next `Hold` (the `tellCueFired` reset).
- A raptor put down during `Hold` before the lead point emits **zero**.
- `consume_audio_cues()` returns the count once and resets it to zero.
- Determinism: two identically seeded worlds produce identical per-tick
  `raptorTells` sequences across a full wave.

Then `scripts/smoke.sh --autotest` for the suite and `scripts/smoke.sh` for a
launch check. Use `REX_MUTE=1` for any manual run.

## Explicitly out of scope

- **Hit confirmation.** Deliberately absent; the reference has none.
- **Boss audio** — arrival, rage-phase escalation, QTE sting, kill. The
  single largest remaining gap after this slice, and the natural next one.
- **Player hurt** — 15 damage still lands silently. Slice 3.
- **Jungle ambience bed.** Needs a second looping channel; `AudioEngine` has
  no ambience concept today.
- **UI cues.** `playUIClickSound` already exists, unused — title, join and
  grade screens are a cheap slice on their own.
- **Rumble parity for the tell.** Tempting, but a road raptor targets no
  specific player, so which pad buzzes in 2P is an unanswered design
  question. Do not improvise it here.
