# Herbivores and protected targets

**Status: spec.** Implementation to follow in three slices.

Closes TODOS item 2 ("don't-shoot protected targets"), and spends the four
converted-but-unused Quaternius herbivores.

## Why now

Two facts make this the right next move:

1. **The assets are already paid for.** `assets/characters/dinos/` holds
   triceratops, stegosaurus, parasaurolophus and apatosaurus, each with a
   full idle/walk/run/attack/jump/death clip set, converted to usdz and
   sitting unused. `DinoSpecies` has exactly two entries.
2. **Every animal on screen is currently a thing to shoot.** "Knowing what
   NOT to shoot is itself a skill" is the design doc's own framing of the
   mastery identity, and right now the game has no way to express it.

## Design decisions

**1. Species enum grows to six.** Order fixed as Velociraptor, Trex,
Triceratops, Stegosaurus, Parasaurolophus, Apatosaurus. Appending only —
`DinoSpecies` is serialized into replay headers and the score timeline, so
reordering would silently invalidate every recording.

Clip durations, measured from the assets themselves via `MDLAsset` (the
same device-free path `ClipDurationTests` uses). The velociraptor and trex
rows reproduce the existing table exactly, which is what makes the other
four trustworthy:

```
    {{ 76.f/30,  74.f/30, 18.f/30, 26.f/30, 35.f/30, 40.f/30}}, // Velociraptor
    {{ 76.f/30,  43.f/30, 29.f/30, 36.f/30, 45.f/30, 49.f/30}}, // Trex
    {{ 78.f/30,  89.f/30, 25.f/30, 24.f/30, 51.f/30, 55.f/30}}, // Triceratops
    {{ 78.f/30,  89.f/30, 25.f/30, 58.f/30, 45.f/30, 49.f/30}}, // Stegosaurus
    {{ 76.f/30,  36.f/30, 18.f/30, 26.f/30, 41.f/30, 40.f/30}}, // Parasaurolophus
    {{129.f/30, 158.f/30, 45.f/30, 58.f/30, 56.f/30, 49.f/30}}, // Apatosaurus
```

**2. One species→name mapping, not three.** The species-name↔directory
association is currently written out by hand in three places:
`RexRenderer.mm`'s `speciesDirs`, `ClipDurationTests`' two local arrays,
and `World.mm`'s `bossConfig.species == "velociraptor"` string compare
(plus `ChartLoader`'s "is not a loadable character" validation list). At
two species that is survivable; at six, one forgotten array is an
out-of-bounds read in a test. Fold it into `DinoSpecies_name()` /
`DinoSpecies_from_name()` next to the enum, and have all four call it.

This is the load-bearing part of slice 1: it is why adding the *fifth*
species later costs one table row instead of a bug hunt.

**3. Protected is a faction, not a flag.** `FactionComponent::Type` gains
`Protected`. It is the semantically right home — the existing damage and
targeting code already asks about factions — and it means "may not be
shot" is answerable without knowing which species is which.

**4. Herbivores cross; they never chase.** No Approach/Hold/Tell/Attack
cycle, no interrupt window, no weak point. A `herd_crossing` chart event
spawns them at a rail distance behind the jeep (which is where the camera
looks) with a lateral velocity that carries them across the road and out
of frame, where they deactivate and return to the pool.

Deliberately NOT reusing `DinoBehaviorState`'s attack states with the
attack disabled: a herbivore that is internally "about to lunge but
suppressed" is a bug waiting to be re-enabled by a future edit to shared
code.

**5. They must READ as protected before they are shot, not after.** A
penalty the player cannot anticipate is a gotcha, not a skill. They get a
distinct non-threat treatment (the legibility pass's vocabulary, inverted:
no red weak-point brackets, a calm outline instead), and they walk rather
than run. If the demo autopilot cannot tell them apart from the data the
renderer draws from, neither can a player — see verification below.

**6. The penalty is -50 and the streak.** Symmetric with
`InterruptSuccess`'s +50, and it breaks the streak exactly as
`InterruptFail` does. It is tracked as `protectedHits` on
`PlayerScoreState`, printed on the grade screen, and denies the S tier
outright — S already "demands real interrupt play", and mowing down the
herd should not be compatible with a top grade.

**7. Target pool grows 7 → 10.** Slots 0-5 raptors, 6 the boss (hardcoded
in several places, leave it), 7-9 herbivores. Growing rather than sharing:
a herbivore that recycles a raptor slot inherits that slot's pursuer
recycling rules in `RailCameraSystem::update_targets`, which is the exact
class of accident decision 4 is avoiding.

## Slices

**Slice 1 — species plumbing.** Enum to six, the measured clip-duration
rows, the single name↔directory mapping with all four call sites moved
onto it, renderer loads all six. No gameplay change.

*Verification:* `test_tableMatchesAssetMetadataWithoutAMetalDevice` covers
whatever `DinoSpecies::Count` says, so it goes from checking 14 clips to
42 for free — and it fails loudly on a wrong row (proven: it caught the
LFS pointer breakage naming the exact species and clip). Add a capture
frame with all six on screen.

**Slice 2 — protected targets on screen.** `Protected` faction, pool
growth, the `herd_crossing` chart event and its loader validation, the
crossing behavior, the non-threat rendering treatment.

*Verification:* a scenario test that a crossing herd enters, crosses and
leaves without ever entering an attack state or damaging the player; the
soak still completes an act.

**Slice 3 — scoring and legibility.** `ProtectedHit` event, -50 and the
streak break, `protectedHits` through to the grade screen and the S-tier
gate.

*Verification:* a scenario test that shooting a herbivore costs 50 and
resets the streak; and the autopilot must skip protected targets in
`pick_target`, with a soak assertion that a full act ends with **zero**
protected hits. That last one is the real legibility test: the bot picks
targets from the same data the renderer draws from, so if the bot cannot
distinguish a herbivore, the player has not been given the information
either.

## Explicitly out of scope

- Herbivores as *bosses* (Triceratops as an act-2 boss is TODOS item 12,
  and wants the chart work, not this).
- Herd AI — flocking, panic, reacting to gunfire near them.
- Any change to raptor or boss behavior, or to the interrupt window.
- The interrupt-reachability finding from PLAN-DEMO-CAPTURE.md. Still
  open, still unfixed, deliberately not bundled here.
