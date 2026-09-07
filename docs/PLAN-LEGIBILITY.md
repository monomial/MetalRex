# Plan — Legibility pass: the three invisible mechanics

Workflow contract: same as M0-M4a, the encounter-feel pass, and the audio tell
(see PLAN-M1.md) — Claude plans, Codex implements.

Design reference: [DESIGN.md](DESIGN.md) "What Makes This Cool" (reading the
animal IS the scoring system), Premise 6 (per-player arrays), Premise 8
(per-player health), and [PLAN-AUDIO-TELL.md](PLAN-AUDIO-TELL.md), which this
continues.

## Why this pass exists

The game scores three things it never shows you. Each is a working mechanic
with a real point value that a player has no way to learn except by accident.

1. **The interrupt window is invisible.** `d28e0d2` gave it a 450ms audio
   warning and `38d16d3` widened it to 145ms, but nothing on screen says
   *now*. The player hears "incoming" and then guesses.
2. **Weak points are invisible.** `RailCameraSystem.mm:261` maintains a live
   weak-point box every frame — `screenHalfW * 0.55` wide, offset
   `screenHalfH * 0.65` up, i.e. the head — and `ReticleSystem.mm:216`
   hit-tests against it for **25 points versus 10**. The renderer draws
   nothing for it. Its only appearance anywhere in the UI is a tally on the
   grade screen (`RexRenderer.mm:1366`), after the run is over.
3. **In 2P you cannot tell who got hit.** `RexRenderer.mm:2196` takes
   `maxHitFlash` as a `std::max` across all players and draws **one shared
   full-screen flash** (line 2261). Both players see an identical screen when
   either is damaged.

And taking damage is nearly unacknowledged: `World::damage_player` sets
`hitFlashTime` and nothing else. No sound (`playHurtSound` exists in
`AudioEngine` with a synthetic fallback and has never been called), no shake
(`ScreenShakeSystem_trigger` has exactly one caller — boss rage escalation,
`DinoBehaviorSystem.mm:261`), no rumble.

This pass is scoped to *legibility only*: no scoring values change, no
behaviour changes, no new encounters. Every number stays where it is; the
player is simply told what the simulation already knows.

## What already exists (do not rebuild)

- **Dino tint chain**, `RexRenderer.mm:750-770`: `uniforms.color` +
  `uniforms.tintStrength`, with hit flash (warm yellow `0.96,0.78,0.24` at
  strength 0.45) taking priority over rage tint (red `1.0,0.30,0.22` at
  `ragePhase * 0.16`). Extend this chain; do not add a second one.
- `kReticleColors[playerIndex]` (`RexRenderer.mm:1693`) — the established
  per-player identity colour, already used for reticles and the grade screen.
- `TargetComponent.weakPointHalfW` / `.weakPointOffsetY` — screen-space,
  recomputed every frame by `RailCameraSystem`, and zeroed for off-screen or
  inactive targets (lines 130, 248). Read them; do not recompute them.
- `BossMajorAttackPoints` and its popup marker drawing — the existing idiom
  for "draw a small marker at a screen-space point on a live dino."
- `AudioEngine playHurtSound` — synthetic fallback present, bundle override
  `sfx_hurt` supported, never called.
- `ScreenShakeSystem_trigger(world, magnitude)`.
- `ControllerRumble.playShootPulse` and the **counter-diff polling pattern**
  the shells use for it (`Rex-tvOS/GameViewController.mm:211-223`,
  macOS equivalent at :160-171): the host exposes a monotonic count, the shell
  diffs it per frame and guards against a restart-to-zero wraparound. Mirror
  this exactly for hurt; do not invent a second mechanism.
- The frame-buffered `AudioCueCounts` contract in `World.h`.
- `World::rand_float01()` for any jitter (TODOS item 5).

---

## Decision 1 — The interrupt window becomes visible

Add to `DinoBehaviorComponent`:

```cpp
// True only while a shot would land inside the interrupt window. Set by
// DinoBehaviorSystem from the same progress value the scoring check uses,
// so the visual and the score can never disagree.
bool interruptWindowOpen = false;
```

Set it in the `Tell`/`Attack` case of `DinoBehaviorSystem_update`, from the
**same** `progress` local the interrupt test already computes:

```cpp
dino.interruptWindowOpen = progress >= dino.interruptStartNormalized
                        && progress <= dino.interruptEndNormalized;
```

Clear it to `false` in `enter_dormant`, `enter_approach`, `enter_hold`,
`enter_retreat`, the `PutDown` path and the `Departing` path — anywhere the
dino leaves the attack cycle. A stuck-open flag is the main risk here.

> Deriving the flag in the sim rather than recomputing progress in the
> renderer is deliberate: one source of truth means the tint cannot drift out
> of sync with the 50-point award, which is exactly the bug that would teach
> players the wrong timing.

Render it by extending the existing priority chain (`RexRenderer.mm:753-770`):

```cpp
bool hitFlash = dino.hitFlashTime > 0.f;
bool window   = dino.interruptWindowOpen;
uniforms.color = hitFlash ? (simd_float4){0.96f, 0.78f, 0.24f, anim.deathFade}
               : window   ? (simd_float4){0.45f, 0.95f, 1.00f, anim.deathFade}
                          : (simd_float4){1.f, 1.f, 1.f, anim.deathFade};
if (!hitFlash && !window && rageTint > 0.f) { /* existing red */ }
uniforms.tintStrength = hitFlash ? 0.45f : (window ? 0.50f : rageTint);
```

Cool cyan-white is chosen to be unmistakable against the two tints already in
use (warm yellow = your shot landed, red = boss rage). Hit flash still wins,
because feedback on your own shot must never be swallowed by a state tint.
Raptors never carry rage and the boss never reaches `Tell`, so the
window/rage branch is defensive rather than load-bearing.

At 145ms the tint is roughly 9 frames at 60Hz — brief but legible. Do not add
a fade-in; the point is a hard edge the player can time against.

## Decision 2 — Weak points become visible

Draw a small marker at the weak-point box for every **active, on-screen,
non-boss** dino, using `target.weakPointHalfW` / `.weakPointOffsetY`
directly. Skip any target whose `weakPointHalfW <= 0.f` — that is already the
system's "no weak point right now" signal (`ReticleSystem.mm:27`).

Bosses are excluded: they are immune to normal fire and carry their own
`BossMajorAttackPoints` markers during the QTE. Two marker vocabularies on one
animal would be worse than none.

Keep it anatomical, not a UI sticker: a thin reticle-agnostic ring or bracket
pair at ~60% opacity, sized from `weakPointHalfW` so it scales with the dino's
distance. It must not compete with the player's own reticle for attention.

> If a three-raptor wave reads as cluttered, the fallback is to draw the
> marker only while some player's reticle is within ~2x `weakPointHalfW` of
> it. Prefer the always-on version first — the mechanic has to be *learnable*
> before it can be *subtle* — and only fall back if it genuinely reads badly.

## Decision 3 — Damage says who, and lands

**a. Per-player flash.** Replace the shared `maxHitFlash` quad
(`RexRenderer.mm:2196, 2261`) with one flash per hurt player, tinted
`kReticleColors[p]`. With a single active player it may still span the screen
as today. With two, anchor each to the side its HUD already occupies, so the
flash identifies its owner without a legend. Preserve the existing alpha
curve (`clamp(t / 0.35f) * 0.35f`) so the intensity is unchanged.

**b. Sound.** Add `int playerHurts = 0;` to `AudioCueCounts`, incremented in
`World::damage_player` **after** the `sittingOut` / `invulnTime` early-out, so
grace-period no-ops stay silent. Drain in `RexGameHost::_playAudioCues` with
`playHurtSound`, capped at 2 voices like the tell.

**c. Shake.** One `ScreenShakeSystem_trigger(world, 0.18f)` per damage event,
from `damage_player`, past the same early-out. Slightly stronger than a boss
phase-1 escalation (0.12 x 1) because it is about *you*.

**d. Rumble on the pad that got hit.** Add `uint32_t hitCount` to
`PlayerHealthState`, incremented alongside the other damage effects. Expose
`- (uint32_t)hurtCountForPlayer:(int)playerIndex;` on `RexGameHost` beside
the existing `shotCountForPlayer:`, and poll it in **both** shells with the
same diff-and-wraparound-guard pattern used for shots. Add
`- (void)playHurtPulse;` to `ControllerRumble` — longer and heavier than
`playShootPulse`, and a no-op on pads without haptics like everything else
there.

This is the only part of the pass that reaches per-player output, and it is
the payoff: in 2P, the player who got bitten feels it in their own hands.

---

## Implementation order

Each step builds green and is independently verifiable.

1. Decision 1 sim flag + its lifecycle (tests before any renderer work).
2. Decision 1 tint.
3. Decision 3b/3c (hurt sound + shake) — pure cue plumbing, pattern already
   proven by the tell.
4. Decision 3d (hitCount, host accessor, both shells, rumble pulse).
5. Decision 3a (per-player flash).
6. Decision 2 (weak-point markers) — last, because it is the most likely to
   need a visual tuning pass and the least likely to break anything.

## Test plan

Renderer output is not unit-testable here, so tests pin the **sim** contracts
that drive it. Extend `DinoBehaviorTests.mm`, `HealthTests.mm`, `ScoringTests.mm`:

- `interruptWindowOpen` is true on exactly the ticks where a shot would score
  `InterruptSuccess`, and false on every other tick of a full activate ->
  put-down cycle. Assert this by driving both paths from the same run rather
  than trusting two separate computations.
- The flag is false after `enter_dormant`, `enter_hold`, `enter_retreat`,
  `PutDown` and `Departing` — one case each, since a stuck-open flag is the
  main risk.
- A raptor put down before the window opens never sets it true.
- `damage_player` increments `playerHurts` and `hitCount` exactly once per
  landed hit, and **not at all** during `invulnTime` grace or while
  `sittingOut`.
- Two dinos landing attacks on the same tick against the same player produce
  exactly one hurt cue and one `hitCount` increment (the invuln gate).
- In 2P, damaging P2 increments only P2's `hitCount`.
- `consume_audio_cues()` returns `playerHurts` once and resets it.
- Determinism: two identically seeded worlds produce identical per-tick
  `interruptWindowOpen`, `playerHurts` and `hitCount` sequences.

Then `scripts/smoke.sh --autotest` and `scripts/smoke.sh`. Use `REX_MUTE=1`
for any manual run. Note that `smoke.sh` may fail in a sandbox on signing or
`testmanagerd` — if so, say so plainly rather than reporting green.

## Explicitly out of scope

- **Any scoring value or behaviour change.** Hit 10 / WeakPoint 25 /
  Interrupt 50 stay exactly as they are. This pass only makes them visible.
- **Retuning `kTellLeadSeconds` or `interruptEndNormalized`.** Both were just
  set and neither has been felt with a controller yet. Changing them in the
  same pass that adds their visuals would make a bad result impossible to
  attribute.
- **Hit confirmation audio.** Still deliberately absent — the arcade
  reference has none.
- **Boss audio** (arrival, rage escalation, QTE sting, kill) — the natural
  next slice, but it is presentation for a fight that is already legible via
  the health bar and rage tint, so it ranks below these three.
- Ambience bed, UI cues, calibration UI, score persistence.
- The level/chart editor, new encounters, new species.
