# Milestone 3 Plan — First Dino: Asset Pipeline + Behavior/Interrupt System

Workflow contract: same as M0-M2 (see PLAN-M1.md, PLAN-M2.md). One difference
this milestone: **Phase 1 cannot be delegated to Codex at all** — it requires
Blender, which is installed on this machine but not in Codex's sandbox (which
also can't launch GUI apps, per the last three tasks). Claude does Phase 1
directly. Phase 2 is a normal Codex task.

Design reference: [DESIGN.md](DESIGN.md) Premise 4, Next Steps' M3 entry, and
the Test Plan's `DinoBehaviorTests.mm` row.

## Ground truth from asset inspection (real files, not assumptions)

All 6 species (`assets/characters/dinos/*.fbx`, committed via LFS) were opened
in headless Blender and inspected directly:

- **29 bones each**, all armatures named `"Armature"` — well under the
  engine's 64-bone GPU skinning cap (closes eng-review Open Question 2a).
- **One FBX per species, 6 embedded animation actions**: Idle, Walk, Run,
  Attack, Jump, Death. Confirms Premise 3/4's "clips embedded in one file"
  assumption — this is NOT Mixamo's file-per-clip layout the existing
  `tools/convert_to_usdz.py` (not yet vendored into this repo) was written for.
- **No interrupt/stagger clip exists.** The dino-mastery scoring identity's
  tell→attack→interrupt mechanic has no dedicated animation to play on a
  successful interrupt. Decision (below): repurpose the Jump clip as the
  interrupt-reaction stand-in rather than block on new animation work.
- **`Apatosaurus.fbx` has one misnamed action**: `"Stegosaurus_Death"` instead
  of `"Apatosaurus_Death"` (a Quaternius authoring artifact — the action data
  itself is valid and correctly bound to the Apatosaurus armature). Any
  exact-string clip matching (`"<Species>_<Clip>"`) will silently miss this.
  Decision (below): match by clip-type suffix at conversion time, not by full
  name, and normalize output filenames so the runtime never sees this quirk.
- **No UV maps on any mesh.** Quaternius's flat-shading technique instead:
  each mesh is split across ~5 solid-color material slots (verified on T-Rex:
  Green/Black/LightGreen/Red/LightYellow, each a plain Principled BSDF base
  color, no texture image). `SkinnedVertex` (Shaders/SkinnedMesh.metal) has no
  color attribute today — position/normal/texcoord/joints only — and
  `LoadedCharacter` (CharacterLoader.h) has a single `diffuseTexture`, assuming
  every character is texture-mapped like the original Mixamo humans.
- **Blender.app is installed** on this machine (`/Applications/Blender.app`),
  confirming the existing FBX→USDZ pattern (FBX is unsupported by ModelIO on
  macOS 14+) is usable here — but the conversion script itself needs adapting
  for Quaternius's layout and needs to run outside Codex's sandbox.
- `kBakedFPS = 30` in `CharacterLoader.h` resamples any source frame rate to a
  fixed 30fps at bake time — no FPS-matching concern during conversion.

## Decisions this plan makes (stated explicitly, not left implicit)

1. **Bake Quaternius's flat multi-material coloring into per-vertex color at
   conversion time**, not as a runtime multi-material/multi-draw-call system.
   Extend `SkinnedVertex` with a `float4 color` attribute (default white for
   every existing Mixamo character — zero behavior change there) and multiply
   it into the existing texture-sample path in the fragment shader
   (`base = mix(texColor.rgb * vertexColor.rgb, tint.rgb, tintStrength)`).
   Dinos get a 1×1 white fallback texture and real vertex colors; humans keep
   their real texture and a white vertex color. One shader path, not two.
2. **Normalize clip identity at conversion time, not runtime.** The Blender
   script matches each source action by suffix (`_Idle`, `_Walk`, `_Run`,
   `_Attack`, `_Jump`, `_Death`, case-insensitive), regardless of the action's
   species prefix, and always exports canonically-named output files
   (`idle.usdz`, `walk.usdz`, ... per species subfolder). This is what fixes
   Apatosaurus's mislabeled action — the runtime C++ loader never needs fuzzy
   string matching, it just expects 6 canonically-named files per species dir.
3. **Interrupt reaction repurposes the Jump clip** (a quick, energetic,
   non-looping motion — the closest fit among what exists) rather than
   blocking this milestone on new animation assets. Track a proper stagger
   clip as a TODO for hero-asset work, not a blocker here.
4. **Convert all 6 species now, wire up only the raptor.** The conversion
   pipeline costs the same per species once it exists; doing all 6 now avoids
   re-running Blender later for content milestones. But `DinoBehaviorSystem`
   and the actual tell/attack/interrupt encounter logic only needs to prove
   itself once — building all 6 species' behavior now would be scope creep
   against "first Quaternius dino through the generalized loader."

## Phase 1 — Asset conversion (Claude, direct, this machine, requires Blender)

Write a Quaternius-specific conversion script (new file, e.g.
`tools/convert_dinos_to_usdz.py` — do not overwrite `tools/convert_to_usdz.py`,
which isn't even vendored into this repo yet and serves the original
Mixamo/file-per-clip layout if that's ever ported over):

1. For each of the 6 species FBX files: import once, locate the armature and
   mesh, bake each material's base color into per-vertex color across the
   faces it's assigned to (Blender's vertex-color-from-material bake, or
   manual per-face color assignment — pick whichever is more reliable once
   attempted), then discard the materials themselves (not needed after baking).
2. Match the 6 actions by suffix (case-insensitive `_idle`, `_walk`, `_run`,
   `_attack`, `_jump`, `_death`), independent of the actual action name prefix.
   Fail loudly (raise, don't silently skip) if fewer than 6 matches are found
   for a species — this is the same "fail loud, not silent" discipline as the
   rest of this design, applied at conversion time.
3. Export per species into `assets/characters/dinos/<species>/`: one base-mesh
   USDZ (T-pose, vertex colors baked in, no materials/textures needed) plus
   six canonically-named animated USDZ clips (`idle.usdz`, `walk.usdz`,
   `run.usdz`, `attack.usdz`, `jump.usdz`, `death.usdz`), each trimmed to its
   action's actual frame range — same pattern as the existing
   `tools/convert_to_usdz.py`'s per-clip export, adapted for one source file.
4. Species names: lowercase directory names (`trex`, `velociraptor`,
   `triceratops`, `stegosaurus`, `parasaurolophus`, `apatosaurus`).

**Verification (Claude, before moving to Phase 2):**
- Run the script via `/Applications/Blender.app/Contents/MacOS/Blender --background --python tools/convert_dinos_to_usdz.py` and confirm it completes without error for all 6 species.
- Re-inspect at least one output USDZ (e.g. via a small ModelIO/`MDLAsset` smoke check, or re-opening in Blender) to confirm vertex colors survived the round-trip and the mesh isn't empty.
- Confirm all 6 species produced exactly 7 files each (1 base + 6 clips) with no missing clip.
- Commit the converted USDZ files (via LFS, per `.gitattributes`) as their own commit before starting Phase 2 — keeps "asset conversion" and "engine code" as separately reviewable/revertable history, matching this repo's existing commit discipline.

## Phase 2 — Engine generalization + first dino (Codex task)

Full scope for the Codex dispatch:

1. **Generalize `LoadedCharacter`/`CharacterLoader` away from the single
   global `AnimClipID` enum** to a per-species clip table (a small
   fixed-size array or map of 6 named clip slots is sufficient — doesn't need
   to be more dynamic than that). Extend `SkinnedVertex`/`SkinnedMesh.metal`
   with the `float4 color` vertex attribute per Decision 1 above; update the
   fragment shader to multiply it in; confirm existing Mixamo-character
   rendering is pixel-identical (white vertex color = no visual change).
2. **Load-time validation**: fail loudly (assertion or clear error log) if a
   species' clip table is missing any of the 6 required clips — the
   fix from the M1/eng-review that must not be dropped when the loader
   changes shape.
3. **Wire the raptor into the existing scene.** Replace one of M1/M2's
   placeholder box targets with the real skinned Velociraptor mesh, driven by
   the per-species `AnimationComponent`/`AnimationSystem` already in the
   engine (unchanged) and positioned via the same rail-relative placement
   `RailCameraSystem` already established in M2 — reuse, don't rebuild, the
   rail-distance/lateral-offset target placement from M2.
4. **`DinoBehaviorSystem`**: a state machine per dino instance — Idle → Tell
   → Attack → (Interrupted | Landed) → back to Idle. "Tell" and the
   interrupt-eligible window are sub-ranges of the Attack clip's own timeline
   (e.g. early frames = wind-up/tell, a window within that = interruptible,
   later frames = the committed hit) — there is no separate tell clip, this is
   driven by clip time, not a distinct animation. On a successful interrupt
   (a hit registered during the window — hit-testing already exists from M1),
   play the Jump clip as the interrupt-reaction stand-in (Decision 3) and
   return to Idle without completing the attack. On a missed window, let the
   Attack clip complete normally. `DinoBehaviorSystem` should expose the
   interrupt outcome (succeeded/failed this cycle) as queryable state — it
   does NOT compute score or apply player damage; that's M4a's job reading
   this system's output, not something to build now.
5. **System tick ordering**: slot `DinoBehaviorSystem_update` per the design
   doc's already-decided ordering (after `RailCameraSystem`, before where
   `ScoringSystem`/`HealthSystem` will eventually sit) — see DESIGN.md's
   "System Tick Ordering" section.

**Explicitly out of scope for Phase 2 (do not build):**
- Scoring, health, or damage — M4a. `DinoBehaviorSystem` only needs to expose
  interrupt success/failure as state; consuming it for points/health is later.
- The other 5 species' behavior/encounters — assets exist after Phase 1, but
  only the raptor gets wired into gameplay this milestone.
- Any change to `ReticleSystem`, the gyro/stick aim model, or fallback-assist
  tuning — settled, out of scope, same fence as M2.
- "Don't-shoot" targets, hero-asset upgrades, rare-behavior tags — all
  already tracked in TODOS.md, not this milestone.
- Determinism/replay harness changes — M4b.

## Acceptance criteria

- Phase 1 output exists and is verified per Phase 1's own verification steps
  above, committed before Phase 2 starts.
- `xcodegen && xcodebuild -scheme Rex-macOS ...` and the tvOS equivalent both
  succeed.
- `RexLogicTests` gains `DinoBehaviorTests.mm` (named in DESIGN.md's Test
  Plan) covering: interrupt-within-window cancels the attack and transitions
  to the Jump reaction; a miss lets the attack clip complete; an incomplete
  per-species clip table fails loudly at load (not silently).
- All prior tests (`WorldSmokeTests`, `ReticleInputTests`, `RailCameraTests`,
  `ChartLoaderTests`) still pass unmodified in behavior.
- Launched on macOS: the raptor renders as a real skinned, colored mesh (not
  a placeholder box), animates through its clips, and can be interrupted by
  landing a hit during its tell window.

## Verification (Claude, after Phase 2)

```sh
cd ~/workspace/MetalRex
xcodegen
xcodebuild -scheme Rex-macOS -derivedDataPath .build/DerivedData build -quiet
xcodebuild -scheme Rex-tvOS -destination 'generic/platform=tvOS' -derivedDataPath .build/DerivedData build -quiet
xcodebuild -scheme RexLogicTests -destination 'platform=macOS' -derivedDataPath .build/DerivedData test
scripts/run.sh   # eyeball: real raptor mesh, colored (not white/untextured), animating, interruptible
```

## Out of scope for M3 (next milestones)

Scoring/health (M4a), determinism/replay (M4b), Act 1 content + 2P join
(M5a/M5b). See DESIGN.md's Next Steps.
