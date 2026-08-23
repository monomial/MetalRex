# Plan — Encounter Feel Pass (raptor outcomes, entrances, health, animation variety)

Workflow contract: same as M0-M4a (see PLAN-M1.md) — Claude plans, Codex
implements. No Blender/GUI dependency; every change here is C++/ObjC++ plus
one JSON schema extension.

Design reference: [DESIGN.md](DESIGN.md) Premise 2 (screen-space reticle),
Premise 6 (per-player arrays), Premise 8 (per-player health), and
[TODOS.md](TODOS.md) items 5 (determinism), 7 (hit-testing), 9 (boss phases).

## Why this pass exists

The chase currently reads as janky, and playtesting narrowed it to four
causes that are independent of the boss/raptor phase-separation problem
(which is deliberately **out of scope** here — see the last section):

1. **Three outcomes where the genre has two.** A raptor can be killed,
   interrupted-but-left-alive, or land its hit. The middle one shouldn't
   exist.
2. **Twelve identical entrances.** Every raptor in the act arrives the same
   way: running up from directly behind, gap 8-9, lane within ±1.7.
3. **Health is a constant (3) regardless of spawn geometry or player count.**
   A close spawn and a far spawn are equally durable, so a close spawn is
   simply unavoidable damage.
4. **Both exits look identical** — an instant `target.active = false` pop.

Encounter *density* is already close to right and is NOT changing: 12 raptor
lunges across ~27s of rail, 15 damage each against 100 player HP, so ~6
unshot lunges are fatal. Leave the counts alone.

## Ground truth: kill-or-one-attack is correct, do not "fix" it

A raptor attacks exactly once and then leaves the field. This is the arcade
grammar and it is intentional. Do **not** make road raptors persistent
re-attackers — that behavior is correct only for `dino.arena` raptors in the
post-boss holdout, which is a bounded encounter. The road chase gets its
tension from a stream of fresh entrances, not from durable enemies.

## What already exists (do not rebuild)

- `DinoBehaviorComponent` state machine and the Approach/Hold/Tell/Attack
  cycle in `RexEngine/Simulation/Systems/DinoBehaviorSystem.mm`.
- `TargetComponent.verticalOffset` — already declared and already consumed by
  `RailCameraSystem.mm` (`worldCenter.y = kGroundWorldY + halfHeight + verticalOffset`).
  Nothing authors it yet. This is the hook for elevated/canopy entrances.
- `ParticleSim::spawn_burst(x, y, z, n, speed, size, r, g, b, seed)` in
  `RexEngine/Renderer/ParticleSim.cpp` — pure C++, takes a colour.
- `AnimationComponent.deathFade` — screen-door dissolve the shader honours.
- `AnimationSystem_clip_duration(world, entity, slot)` — needed for the health
  window computation.
- `World::rand_float01()` — deterministic xorshift. **Use this for all jitter
  below**; do not use `rand()`/`drand48()` (TODOS item 5).
- Scoring values in `ScoringSystem.mm`: Hit 10, WeakPointHit 25,
  InterruptSuccess 50. These stay as-is.

---

## Decision 1 — Two outcomes, four grades

A raptor leaves the field in exactly one of two ways:

| outcome | trigger | player damage |
|---|---|---|
| **Put down** | `dino.health <= 0` **or** a shot lands inside the interrupt window | none |
| **Struck** | the Attack clip completes unopposed | `damage_player(attackDamage)` |

The current third path — `wasShot && inWindow` sending the raptor to
`DinoBehaviorState::Interrupted` → `Retreat` → `Dormant` at **full health** —
is removed. An interrupt is a put-down.

**Scoring is unchanged and carries the mastery layer.** The grade comes from
*when* you put it down, which the existing events already encode:
body shot 10 / weak point 25 / interrupt-window put-down 50. So a
last-instant read-the-tell save is worth 5x a lazy early body shot, which
preserves the "reading the animal's tells is the scoring system" identity from
DESIGN.md without a third outcome.

### State machine changes

- Rename `DinoBehaviorState::Dying` → `PutDown`. Update
  `RexLogicTests/DinoBehaviorTests.mm` and any other references (mechanical).
- Add `DinoBehaviorState::Departing` — the post-strike exit (Decision 4).
- Remove `DinoBehaviorState::Interrupted` and `jumpReactionDuration`. The
  interrupt path now routes into `PutDown` directly.
- Keep `DinoInterruptOutcome` — `ScoringSystem` still keys off it.

### Kid-friendly put-down (no death)

This is a kid-friendly game. Dinosaurs are never depicted as dying.
`CharacterClipSlot::Death` must no longer be requested for raptors (leave the
enum and the loaded clip in place; simply stop selecting it).

`PutDown` plays, in order, over ~0.4s total:
1. `AnimationSystem_force_clip(..., CharacterClipSlot::Jump)` — the recoil/
   startle the interrupt path already used.
2. One `ParticleSim::spawn_burst` at the target's world position — a dust/leaf
   puff. Warm tan (approx r 0.72, g 0.62, b 0.42), ~14 particles.
3. `deathFade` drives to 0, then the slot returns to the dormant pool
   (existing `enter_dormant`).

Keep it fast — at ~1 lunge every 2.2s a lingering reward beat stacks up.

---

## Decision 2 — Health is derived from the shooting window, never authored

Replace the hardcoded `maxHealth = 3` (set in `World::reset_m1_scene`) with a
value computed at activation time in `activate_raptor_wave` and
`DinoBehaviorSystem_spawn_arena_raptor`.

### The window

Time from the dino becoming targetable to the last instant a shot can still
put it down:

```
closingRate   = max(0.1, chaseSpeed - camera.speed)
approachTime  = max(0, spawnGap - attackRange) / closingRate
holdTime      = holdDuration + attackDelay
tellTime      = interruptEndNormalized
              * AnimationSystem_clip_duration(world, id, CharacterClipSlot::Attack)
              / kAttackClipSpeedMultiplier      // 4.0, see clip_speed_multiplier
window        = approachTime + holdTime + tellTime
```

### The health

```
health = clamp(lround(kHealthPerWindowSecond * window * activePlayerCount), 1, kMaxDinoHealth)
```

with, as new constants in `Components.h`:

```cpp
static constexpr float kHealthPerWindowSecond = 0.6f;
static constexpr int   kMaxDinoHealth         = 6;
static constexpr float kMinFairWindowSeconds  = 0.9f;
```

`activePlayerCount` = players with `reticle.active && !player_health(p).sittingOut`.
Add `int World::active_player_count() const` next to the existing
`any_player_active_and_not_sitting_out()`. If it returns 0, treat as 1.

**Calibration check — this preserves current balance.** The default chase
spawn (spawnGap 8, attackRange 2.4, chaseSpeed 3.55, camera 1.2, hold 2.0)
gives approachTime ≈ 2.38s, window ≈ 4.6s, so 1P health = round(0.6 × 4.6) = 3
— exactly today's constant. 2P doubles it to 6. A 1.5s close-ambush window
yields 1. Verify this in a test rather than trusting the arithmetic here.

### Fairness gate

If a computed `window < kMinFairWindowSeconds`, the spawn is unfair regardless
of health — nobody can acquire and fire that fast. Log a loud warning naming
the wave label and clamp the window up to `kMinFairWindowSeconds` for the
health computation. Do not silently accept it.

Set both `dino.maxHealth` and `dino.health` to the computed value.
Boss health is unaffected — it stays chart-authored (`BossChartConfig`) and
the boss remains immune to fire.

---

## Decision 3 — Spawn archetypes (entrance variety)

Entrance variety is **pathing, not new animation data**. Same six clips.

### Hard engine constraints — respect these, do not fight them

1. **The camera faces backward** (`RailCameraSystem.mm`, `lookBack = distance - kLookBackDistance`).
   All spawns live behind the jeep. Head-on entrances are out of scope.
2. **Depth is capped at 12 units.** `RailCameraSystem_update` recycles any
   target with `gap > 12.f`. Every archetype's `gap` must stay ≤ 11.5.
3. **Wide lateral offsets collapse to the screen edge** — the frustum clamp
   slides any target back inside the horizontal FOV. Lateral beyond the
   frustum is not expressive; get "off to the side" from a *small gap*
   (narrow frustum) instead of a large lateral.

### Archetype table

Add a named preset table in `DinoBehaviorSystem.mm` (code, not chart):

| archetype | gap | vertical | holdScale | notes |
|---|---|---|---|---|
| `chase` | 8.0–11.5 | 0 | 1.0 | current behaviour, the default |
| `close_ambush` | 2.8–4.0 | 0 | 0.45 | bursts in beside you; low health falls out of the short window |
| `canopy_drop` | 4.0–6.0 | +2.5 → 0 | 0.70 | falls to ground over ~0.5s during Approach |
| `low_crawl` | 5.0–8.0 | −0.25 | 1.10 | reads under the sightline |

`canopy_drop` needs the only new movement code: lerp `target.verticalOffset`
from its spawn value to 0 over the first 0.5s of `Approach`, ease-out. Play
`CharacterClipSlot::Jump` for the fall, then `Run` on landing.

### Chart schema extension

Extend the `raptor_wave` payload with an optional `entries` array:

```json
{
  "distance": 15.0,
  "type": "raptor_wave",
  "payload": {
    "groupSize": 2,
    "entries": [
      { "archetype": "chase",        "lane": -1.2 },
      { "archetype": "close_ambush", "lane":  2.6 }
    ],
    "holdSeconds": 2.25,
    "attackStaggerSeconds": 0.45,
    "label": "pair-test"
  }
}
```

- `entries` is optional. When absent, fall back to the existing `lanes` array
  with every entry defaulting to `chase` — **all existing charts must keep
  loading unchanged**, and `RexLogicTests/ChartLoaderTests.mm` must still pass
  without edits to its fixtures.
- When present, `entries.count` must equal `groupSize`, and an unknown
  `archetype` string must fail loudly at parse time (same policy as
  `boss.species` — see `parse_boss_config`).
- `gap` within an archetype's range is picked with `world.rand_float01()` at
  activation, so it varies run to run but stays deterministic under a fixed
  seed.

Then update `assets/charts/m2-test.json` to use a mix — roughly half `chase`,
with `close_ambush` and `canopy_drop` sprinkled in. Do not change the number
of waves or the total raptor count.

---

## Decision 4 — Two readable exits

Today both outcomes end in `enter_dormant`, which sets `target.active = false`
and pops the dino out of existence mid-motion. Split them:

- **Put down** → recoil + puff + fade in place over ~0.4s (Decision 1).
- **Struck** → new `Departing` state: apply `damage_player` once, then back
  away using the existing Retreat motion while `deathFade` ramps to 0 over
  ~0.9s. It should read as bounding off and falling behind, not vanishing.

`retreatGap` / `retreatDuration` keep their current values for `Departing`.
Only `dino.arena` and boss entities still re-approach after retreating —
that branch is unchanged.

---

## Decision 5 — Animation variety for free

No new animation data. Three changes:

1. **Per-entity playback rate.** `clip_speed_multiplier(World&, EntityID, CharacterClipSlot)`
   in `AnimationSystem.mm` already takes an entity and never reads it. Add
   `float rateScale = 1.f` to `AnimationComponent` and multiply it in. Assign
   each raptor `0.88 + world.rand_float01() * 0.24` (±12%) at activation.
2. **Run-cycle phase offset.** `begin_transition` resets `clipTime = 0`, so a
   wave activating in one tick starts in lockstep. At activation, after
   forcing `Run`, set `anim.clipTime = world.rand_float01() * clip_duration(Run)`.
3. **Transform-level liveliness** (model matrix only, no bone work): a small
   yaw lean into road curvature and a subtle vertical bob during `Approach`,
   amplitude scaled by `rateScale` so faster animals bob faster.

---

## Decision 6 — Streak bug

`ScoringSystem.mm` currently zeroes `currentStreak` for **both**
`InterruptFail` and `TellMissed`. Under the two-outcome model those fire on
the same failure (the tell completing unshot, then the attack landing), so one
mistake breaks the streak twice. Only `InterruptFail` — an actual landed hit —
should break it. `TellMissed` keeps scoring 0 but must leave the streak alone.

---

## Implementation order

Each step should build green and be independently verifiable.

1. Decision 6 (streak) — smallest, isolated.
2. Decision 1 (two outcomes + kid-friendly put-down), including the state
   rename and test updates.
3. Decision 4 (two exits).
4. Decision 2 (health from window) + `World::active_player_count()`.
5. Decision 5 (animation variety).
6. Decision 3 (archetypes: code table → chart schema → `m2-test.json`).

## Test plan

Extend `RexLogicTests/DinoBehaviorTests.mm` and `ScoringTests.mm`:

- A shot inside the interrupt window puts the raptor down (health reaches 0 /
  state becomes `PutDown`) and the player takes no damage.
- An unopposed attack deals exactly `attackDamage` once, and the raptor enters
  `Departing`, not `Dormant`, on the same tick.
- `CharacterClipSlot::Death` is never requested for a non-boss dino across a
  full activate→put-down cycle.
- Health-from-window: the default chase spawn yields 3 at 1P and 6 at 2P.
- A `close_ambush` spawn yields health 1 and a window ≥ `kMinFairWindowSeconds`.
- `ChartLoaderTests.mm`: a payload with `lanes` and no `entries` still loads
  and defaults to `chase`; an unknown `archetype` throws.
- Determinism: two worlds seeded identically produce identical health, gap,
  and `rateScale` for the same wave.

Run `scripts/smoke.sh --autotest` and confirm the full suite is green, then
`scripts/smoke.sh` for a launch check. Use `REX_MUTE=1` for any manual run.

## Explicitly out of scope

- **Boss/raptor phase separation (`sections` in the chart).** The T-Rex
  currently arrives at `arrivalDistance` 26.0 while waves are authored at
  28.5 and 31.0, so boss and raptors share the screen. That is a real bug and
  it is a *separate* plan — it needs a `sections` schema plus boss re-entry
  (`begin_boss_flee` is currently terminal). Do not start it here.
- The level/chart editor tooling.
- Buying or authoring new animation clips.
- Any change to encounter density or wave counts.
