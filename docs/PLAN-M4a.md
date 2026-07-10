# Milestone 4a Plan — Score + Health

Workflow contract: same as M0-M3 (see PLAN-M1.md/M2.md/M3.md) — Claude plans and
does small mechanical steps, Codex implements. This milestone is a normal
Codex task, no Blender/GUI dependency like M3 Phase 1 had.

Design reference: [DESIGN.md](DESIGN.md) Premise 6, Premise 8, Next Steps'
M4a entry, System Tick Ordering (`ScoringSystem`/`HealthSystem` slots), and
the Test Plan's `ScoringTests.mm`/`HealthTests.mm` rows.

## Ground truth: reconciling the existing ad hoc health system

An earlier session (outside this milestone's planning) already shipped a
health/damage/game-over/continue mechanic ahead of schedule, in response to
direct user request rather than from this plan. It works and is tested
(`RexLogicTests/HealthTests.mm`, 4 tests) but **deviates from Premise 8/6 in
one real way**: it's a single shared `PlayerHealthState` (one jeep-wide health
pool), not per-player arrays. Premise 6 requires reticle/score/health to be
"arrays/maps over player-slot from the first line of code," and Premise 8 is
explicit: *"In 2P, health is per-player (cabinet norm: separate lives): a
depleted player sits out (spectates, reticle hidden) while their partner
continues solo; the run ends when both are out or the act completes."*
Today's `World::tick` freezes the *entire* sim when the single shared health
hits zero — there's no way for one player to sit out while the other keeps
playing, which is the actual cabinet behavior this design calls for.

This plan supersedes the shared-health model with per-player state. The
existing continue ("insert coin") mechanic is kept — it's a reasonable
addition beyond what DESIGN.md specified, not a conflict with it — but
rescoped to be per-player rather than global (see Decision 2 below).

## What already exists (do not rebuild)

- `DinoBehaviorComponent` state machine (Idle/Tell/Attack/Interrupted/Landed/
  Dying), `DinoInterruptOutcome` (`None`/`Succeeded`/`Failed`) — `Failed` is
  already the "attack landed unopposed" signal this milestone's damage and
  scoring both key off.
- `ReticleComponent::shotCount` (diffed by the renderer for tracer VFX) and
  `TargetComponent::wasHit` (set by `ReticleSystem_update` on a successful
  hit-test against a target's screen bounds) — the raw "did player X's shot
  connect with target Y this tick" signal `ScoringSystem` needs.
  `TargetComponent` does not yet know *which player* fired the hit shot —
  needed for per-player scoring (see Decision 3).
- `World::damage_player(int)`, `PlayerHealthSystem_update`, the HUD health
  bar + hit-flash + GAME OVER panel in `RexRenderer::_drawHUD:` — all reused,
  generalized to per-player (Decision 1).
- `RexLogicTests/HealthTests.mm` — extended, not replaced.

## Decisions this plan makes

1. **`PlayerHealthState` becomes `PlayerHealthState _playerHealth[kRexMaxPlayers]`**,
   matching the existing `_reticles[kRexMaxPlayers]` / `_targets[kM1MaxTargets]`
   array-over-slot convention already used throughout `World`. Only players
   with `reticle(i).active == true` participate; an inactive slot's health is
   inert.
2. **Sit-out replaces global freeze; continue becomes per-player.**
   `PlayerHealthState::gameOver` is renamed `sittingOut` (same bool semantics,
   name matches Premise 8's own word) and becomes per-slot. `World::tick`
   still runs `RailCameraSystem`/`DinoBehaviorSystem` as long as **at least
   one** active player is not sitting out (Premise 8: "the run ends when both
   are out"). A sitting-out player's reticle is hidden (renderer already
   checks `reticle.active`; sitting out does not touch `active`, it adds a
   `sittingOut` gate the renderer and `ReticleSystem`/`DinoBehaviorSystem`'s
   damage-targeting both respect — see Decision 3). Pressing fire while
   sitting out revives *that player only* (their own `current_input(i).fire`,
   not any player's) — this is the existing continue mechanic, narrowed from
   "revives everyone" to "revives the player who pressed it," which is both
   more cabinet-accurate (insert *your* coin) and the natural per-player
   generalization. Only when *every* active player is simultaneously sitting
   out does the full-screen GAME OVER panel appear (reusing the existing
   panel verbatim); otherwise a smaller per-player "sitting out — press fire"
   indicator is needed next to that player's (hidden) reticle slot — simplest
   version: reuse the existing health-bar-row real estate, see Decision 5.
3. **Damage-targeting rule: nearest active reticle takes the hit.** Dino
   attacks aren't aimed at a specific player today (there's one shared screen,
   not per-player viewports), so a rule is needed for *who* takes the damage
   when an attack lands unopposed. Rule: among players with `active &&
   !sittingOut`, damage goes to whichever reticle's screen position
   (`ReticleComponent::x/y`) is closest to the attacking dino's `TargetComponent`
   screen position (`screenX/screenY`) at the moment `DinoInterruptOutcome::Failed`
   fires — i.e., "you weren't aiming at the thing that got you." In 1P this is
   just the one active player, so 1P behavior is unchanged. If no player is
   eligible (shouldn't happen — `DinoBehaviorSystem` only runs while at least
   one player is active/not-sitting-out per Decision 2), skip the hit rather
   than crashing.
4. **Scoring event vocabulary** (DESIGN.md M4a bullet, verbatim): a small
   fixed enum — `Hit`, `WeakPointHit`, `InterruptSuccess`, `InterruptFail`,
   `TellMissed` — each with a defined point value and streak-interaction rule:
   - `Hit` (body shot, target damaged): +10, continues the current streak.
   - `WeakPointHit` (shot landed inside the weak-point sub-region, see
     Decision 6): +25, continues the streak.
   - `InterruptSuccess` (shot during the interrupt window — already detected
     by `DinoBehaviorSystem` as `DinoInterruptOutcome::Succeeded`): +50, continues
     the streak. This is the "mastery" event the design's whole identity rests
     on, so it's weighted highest.
   - `InterruptFail` (`DinoInterruptOutcome::Failed` — the attack landed): streak
     resets to 0, no points. This is also the event that triggers
     `damage_player` (Decision 3) — one event, two consumers (`ScoringSystem`
     and the health/damage path), not two separate signals for the same thing.
   - `TellMissed` (a dino's Tell phase ends and transitions into Attack without
     ever being shot at all during Tell — distinct from `InterruptFail`, which
     requires having been in the interrupt window; `TellMissed` is "you never
     even reacted"): streak resets to 0, no points, exists purely as a
     distinct emitted event so `ScoringTests.mm` and any future UI can
     distinguish "shot but too late" from "didn't shoot at all." Emit it once
     per Tell→Attack transition, from the same place `DinoBehaviorSystem`
     already flips `dino.state` from `Tell` to `Attack`, gated on whether any
     hit was registered against that dino during the whole Tell phase (track a
     bool on `DinoBehaviorComponent`, reset when re-entering Tell).
   `DinoBehaviorSystem` emits these via `World::events()` (the existing
   `EventBus` — check `EventBus.h` for its current shape/capacity before
   assuming it fits multi-field payloads; extend it if it's currently
   marker-only). `ScoringSystem_update` (new file, slotted per DESIGN.md's
   System Tick Ordering — after `DinoBehaviorSystem_update`, same tick)
   drains these events and updates per-player score/streak/accuracy state.
5. **Per-player scoring state**, array-over-slot like health:
   ```
   struct PlayerScoreState {
       int score = 0;
       int currentStreak = 0;
       int bestStreak = 0;
       int shotsFired = 0;   // mirror of ReticleComponent::shotCount at last tick, for accuracy%
       int shotsHit = 0;     // Hit + WeakPointHit + InterruptSuccess events attributed to this player
       int weakPointHits = 0;
       int interruptSuccesses = 0;
   };
   ```
   Accuracy % = `shotsHit / max(1, shotsFired)`. Exposed via `World::score(int
   playerIndex)`, same accessor pattern as `reticle(i)`/`target(i)`.
6. **Weak-point sub-region: a fixed fractional sub-rect of the existing
   screen bounds, not a bone-attached hit region.** TODOS.md item 7 already
   flags full weak-point hit-testing (bone-attached regions, occlusion,
   overlapping dinos) as needing real prototyping once dinos exist — that's
   now true, but a full bone-attached system is more than M4a needs to prove
   the scoring vocabulary. v1: add `float weakPointHalfW`/`weakPointOffsetY`
   (as a fraction of `screenHalfW`/`screenHalfH`) to `TargetComponent`,
   computed in `RailCameraSystem::update_targets` as a fixed sub-rect anchored
   at the top of the existing screen bounds (approximates "head/neck" for
   both raptor and T-Rex without needing per-species tuning yet — e.g. top
   35% of the bounds, same horizontal center). `ReticleSystem_update`'s
   existing `point_inside` check gains a second, smaller test against this
   sub-rect; a hit inside it is `WeakPointHit` instead of plain `Hit`.
   Revisit real weak-point tuning per species as a TODOS.md follow-up, not
   blocking this milestone.
7. **Which player gets credit for a hit.** `ReticleSystem_update` already
   knows which player's reticle scored the hit (it's iterating per-player in
   its own loop) — thread that player index through to the event emitted for
   scoring, rather than having `DinoBehaviorSystem` guess. Concretely:
   `TargetComponent` gains a transient `uint8_t lastHitByPlayer` set alongside
   `wasHit` in `ReticleSystem_update`, read (not owned) by `DinoBehaviorSystem`
   when it processes `wasHit` this tick, same lifetime as `wasHit` itself.
8. **End-of-run grade screen is NOT this milestone.** There is no act-length/
   act-end trigger yet (that's M5a's job — an authored chart with a defined
   end). M4a's job is the scoring *system* and *live* HUD readout (score,
   streak, accuracy%, this-run weak-point/interrupt counts) proving the
   vocabulary works, not the final grade-screen UI. Keeps this milestone
   weekend-sized per the design's own discipline (Constraints: "milestones
   must be weekend-sized").

## Phase 1 — Per-player health (Codex task)

1. `Components.h`: rename `PlayerHealthState::gameOver` → `sittingOut`
   (Decision 2). `World.h`/`World.mm`: `_playerHealth` becomes
   `PlayerHealthState _playerHealth[kRexMaxPlayers]`; `player_health()` takes
   a `playerIndex` param (default 0 is NOT appropriate here — every call site
   must pass an explicit index; audit `RexRenderer.mm`'s `_drawHUD:` and
   `PlayerHealthSystem.mm` for the old no-arg call and update both).
2. `World::damage_player` takes a `playerIndex` param; `DinoBehaviorSystem.mm`'s
   call site implements Decision 3's nearest-reticle targeting rule (needs a
   small helper — loop `kRexMaxPlayers`, skip `!active || sittingOut`, track
   min screen-space distance to the attacking dino's `TargetComponent`).
3. `PlayerHealthSystem_update`: per-player invuln/hit-flash timers (unchanged
   logic, just looped over the array); continue-input check becomes
   per-player (`world.current_input(i).fire` revives slot `i` specifically,
   not any active player reviving all).
4. `World::tick`: replace the single `if (!_playerHealth.gameOver)` gate with
   "run gameplay systems if at least one active player is not sittingOut."
   Add a `World::any_player_active_and_not_sitting_out() const` helper (or
   equivalent) used both here and by the renderer to decide whether to show
   the full GAME OVER panel (Decision 2: only when *all* active players are
   sitting out).
5. `ReticleSystem_update`/`DinoBehaviorSystem_update`: a sitting-out player's
   reticle must not aim/fire (gate near the top of `ReticleSystem_update`'s
   per-player loop, alongside the existing `if (!reticle.active) continue;`)
   and must not be eligible as a damage target (Decision 3 already excludes
   `sittingOut` players from the nearest-reticle search).
6. `RexRenderer.mm`: `_drawHUD:` renders one health bar per active player
   (stack vertically or place side-by-side top-center — Codex's judgment,
   constrained to: each bar must be clearly associated with its player,
   reusing the existing per-player reticle colors `kReticleColors` for
   visual continuity). A sitting-out player's bar shows a distinct state
   (e.g. dimmed/empty + "PRESS FIRE" label using the existing
   `Rex_drawCenteredLine`/texture-quad machinery, small variant). The
   full-screen GAME OVER panel keeps its current look, gated on the new
   all-sitting-out condition.
7. Tests: extend `RexLogicTests/HealthTests.mm` — convert existing 4 tests to
   index `player_health(0)` explicitly (behavior for 1P must not change);
   add the two cases DESIGN.md's own Failure Modes table and Implementation
   Tasks (T8) flag as missing:
   - 2P: P1 depleted (sitting out) + P2 active → P2's run continues normally
     (rail/dinos keep advancing), P1's reticle stops responding to input,
     no full-screen GAME OVER panel.
   - 2P: both P1 and P2 depleted simultaneously in the same tick → both sit
     out, full-screen GAME OVER panel condition becomes true, rail/dinos
     freeze; either player's fire press revives only themselves, and the
     panel condition goes false again once at least one is back in.

**Explicitly out of scope for Phase 1:** scoring (Phase 2), weak points
(Phase 2), the end-of-run grade screen (M5a).

## Phase 2 — Scoring system + weak points (Codex task, after Phase 1 lands)

1. `Components.h`: add `PlayerScoreState` (Decision 5); add
   `TargetComponent::weakPointHalfW`/`weakPointOffsetY` and transient
   `lastHitByPlayer` (Decisions 6-7); add a `DinoScoreEvent` enum (`Hit`,
   `WeakPointHit`, `InterruptSuccess`, `InterruptFail`, `TellMissed`, Decision
   4) and whatever payload shape `EventBus` needs extending to carry
   (player index + event type + dino species, at minimum).
2. `RailCameraSystem.mm`'s `update_targets`: compute the weak-point sub-rect
   alongside the existing `screenHalfW`/`screenHalfH` computation (Decision
   6).
3. `ReticleSystem_update`: on a hit, test the weak-point sub-rect first (more
   specific case first — a weak-point hit is still inside the outer bounds,
   so order matters); set `TargetComponent::lastHitByPlayer` to the firing
   player's index alongside `wasHit`.
4. `DinoBehaviorSystem.mm`: emit `Hit`/`WeakPointHit` (reading
   `lastHitByPlayer`) when `wasShot` is true outside the interrupt window (a
   body/weak-point hit that doesn't interrupt anything — e.g. hits while
   `Idle`/chasing, which already drain `dino.health` today); emit
   `InterruptSuccess`/`InterruptFail` at the existing
   `DinoInterruptOutcome::Succeeded`/`Failed` transitions (reusing
   `lastHitByPlayer` for `InterruptSuccess`'s credit; `InterruptFail` has no
   shooter to credit, it's a streak-reset event only); emit `TellMissed` per
   Decision 4's Tell→Attack-with-no-hit-during-Tell rule.
5. New `ScoringSystem.h`/`.mm`: drains `World::events()` each tick, updates
   `PlayerScoreState` array per Decision 4/5's point values and streak rules.
   Slot in `World::tick` after `DinoBehaviorSystem_update`, per DESIGN.md's
   System Tick Ordering.
6. `RexRenderer.mm`: extend the per-player HUD row (Phase 1's health bar) with
   a compact score/streak/accuracy readout — text via the existing
   `Rex_drawCenteredLine`/texture-quad machinery (cache-by-content-hash or
   regenerate only when the displayed numbers actually change, not every
   frame, to avoid a CoreText regen per frame — check what's cheap enough
   before assuming; a simple "only rebuild if the formatted string changed
   since last frame" cache is enough).
7. New `RexLogicTests/ScoringTests.mm` (named in DESIGN.md's Test Plan):
   weak-point hit awards the bonus and not the base `Hit` value; a miss
   (`InterruptFail`/`TellMissed`) resets the streak; P1's miss doesn't affect
   P2's streak/accuracy (per-player independence, DESIGN.md Test Plan's
   explicit case).

## Acceptance criteria

- `xcodegen && xcodebuild -scheme Rex-macOS ...` and the tvOS equivalent both
  succeed after each phase.
- `RexLogicTests` passes with all prior tests behavior-unchanged for 1P, plus
  the new 2P health cases (Phase 1) and `ScoringTests.mm` (Phase 2).
- Visual capture-verify (`--capture-out=`) after each phase: Phase 1 shows
  per-player health bars and correct sit-out/continue/all-out-GAME-OVER
  behavior; Phase 2 shows a live score/streak/accuracy readout that changes
  as dinos are hit.
- 1P behavior is unchanged end-to-end (same feel, same numbers) — Premise 6's
  "zero added scope for the single-player path" carries forward to this
  milestone's refactor, not just M1's original data-shape decision.

## Out of scope for M4a (later milestones)

- Determinism/replay (M4b).
- The end-of-run grade screen UI, act length/act-end trigger (M5a).
- Full bone-attached weak-point regions, per-species weak-point tuning,
  occlusion/overlapping-dino hit-test resolution (TODOS.md item 7 — revisit
  once more encounters exist to test against).
- "Don't-shoot" protected targets (TODOS.md item 2, Open Question 4).
