# TODOS — MetalRex

Captured during /plan-eng-review of the initial design doc (michaelsmith-main-design-20260706-202820.md), before the repo exists. Move this file into the repo root once M0 creates it.

## 1. iPhone-as-light-gun companion app

**What:** A companion iOS app that streams phone-gyro pointing to the TV as an alternative/additional aim input, instead of (or alongside) DualSense gyro.

**Why:** Floated in the original /office-hours session as option C for the aim model — closest to a real light-gun feel, since everyone already owns a phone. Rejected for v1 because it's a project-sized detour (second app, local networking, latency budget, per-player pose drift) versus gyro-first's near-zero marginal cost.

**Pros:** Potentially the best light-gun-like feel achievable on this hardware; removes the "you need a specific $70 controller" barrier to friends playing.

**Cons:** A second app, a local-network pairing/latency problem, and per-player pose drift to solve — real scope, not a quick add.

**Context:** The sim only ever consumes an aim vector (Premise 2's screen-space reticle model), so a phone-based input source is a drop-in replacement for the gyro input path, not a redesign.

**Depends on / blocked by:** M1's gyro-feel verdict. Only revisit if it disappoints, or if TestFlight friends report the DualSense-only requirement as a real adoption blocker.

---

## 2. "Don't-shoot" protected targets (herbivores, NPC vehicles)

**What:** Scoring penalty for hitting protected/non-threat targets — herbivores wandering through a scene, an NPC jeep/helicopter you're escorting.

**Why:** Strong flavor match for the "dino mastery" identity (knowing what NOT to shoot is itself a skill), but adds choreography cost per scene (every protected target needs its own behavior/hitbox/scoring rule).

**Pros:** Meaningfully deepens the mastery-scoring identity; distinguishes this from a generic "shoot everything" rail shooter.

**Cons:** Per-scene authoring cost; risk of over-scoping Act 1 if added without a budget check first.

**Context:** This is Open Question 4 in the design doc, explicitly kept open (not built into v1, not cut) per the eng-review scope decision — the core loop (weak-point + interrupt + streak scoring) works fully without it.

**Depends on / blocked by:** M5's encounter-design budget — how much authoring time remains after the four core encounters (raptor ambush, herd crossing, triceratops charge, T-Rex boss).

---

## 3. Hero-asset upgrade (AI-generated or paid dino models)

**What:** Replace the free Quaternius stylized dinos with higher-fidelity hero assets (AI-generated via Meshy/Tripo, or paid marketplace packs) for the T-Rex boss and other showcase moments.

**Why:** Quaternius gets the whole game built and playable fast (Premise 3), but a photoreal-ish T-Rex boss would read as more "Jurassic" than stylized low-poly. This is the explicit tradeoff made in office-hours: Quaternius-first over AI/paid, precisely so hero-asset quality doesn't block getting the game made.

**Pros:** Could meaningfully upgrade the game's visual identity for TestFlight/showing friends, once the core loop is proven.

**Cons:** Real risk of yak-shaving on asset quality instead of shipping content if started too early — exactly the trap Quaternius-first was chosen to avoid.

**Context:** AI-generated (cheap, but animation quality is the weak link) vs. paid marketplace packs ($100-300, more reliable but need FBX→glTF conversion and license review) — both compared in office-hours.

**Depends on / blocked by:** M5a (Act 1 shareable) complete and proven fun first. Hard gate, not a soft preference.

---

## 4. Revive-on-partner-assist (co-op health mechanic)

**What:** In 2P, instead of (or in addition to) a depleted player sitting out, their partner can revive them mid-run (e.g. shoot a revive icon near the fallen player).

**Why:** Raised by Codex's outside-voice review of this design — permanent elimination in a 2-player couch co-op game benches a friend, which is a bad experience for a game whose whole point is playing together. The plan-eng-review's own "weekend-sized milestone" discipline means a full revive system (state machine, UI, balancing "how easy is too easy") is real scope beyond M5b's sit-out mechanic.

**Pros:** Meaningfully better couch-co-op feel; keeps both friends engaged the whole run.

**Cons:** Real design + implementation work — a revive state machine, UI treatment, and balance pass (too-easy revives trivialize the health mechanic entirely).

**Context:** M5b ships the simpler sit-out model first. This is the natural upgrade once that's proven and if playtesting shows elimination feels bad.

**Depends on / blocked by:** M5b shipped and played with real friends first — decide based on actual playtest reaction, not speculation.

---

## 5. Determinism as a constraint from M1, not M4b

**What:** Treat replay-determinism (same inputs → same outputs) as a design constraint enforced from M1 onward — gyro sampling, render-frame reticle interpolation, animation pose timing, and floating-point hit-test queries all need to be reasoned about as they're built, not retrofitted at M4b.

**Why:** Codex's outside-voice review flagged that M4b (determinism) coming after M1-M3 risks "archaeology" — reconstructing determinism after the fact is much harder than building it in from the start, since several of M1-M3's systems (gyro, animation, rendering) are exactly where floating-point/timing non-determinism creeps in.

**Pros:** Avoids a possible expensive M4b surprise where hit-testing turns out to be subtly non-deterministic and requires reworking M1-M3 systems to fix.

**Cons:** Adds a "is this deterministic?" discipline check to every M1-M3 system, which could slow down the fun-first, feel-driven tuning M1 is supposed to prioritize.

**Context:** This is a genuine tension between "tune aim feel fast and loose" (M1's stated goal) and "build it deterministic from day one" (this TODO's ask). Worth a conscious decision at M1 kickoff, not a silent default either way.

**Depends on / blocked by:** M1 kickoff — decide the discipline level before writing the gyro input code.

---

## 6. Audio as a core feel system, not deferred polish

**What:** Hit confirmation sounds, danger tells (audio cue before a dino attacks), boss anticipation stings, and grade-screen feedback — currently unplanned (Open Question 7 just says "sourcing not yet planned").

**Why:** Codex's outside-voice review argued audio is core to whether M1's "does aiming feel good" gate can even be judged fairly — a hit with no sound feedback feels worse than the aim system deserves, potentially producing a false-negative on the go/no-go milestone.

**Pros:** Protects M1's go/no-go judgment from being contaminated by missing audio feedback; audio is often the cheapest "make it feel 10x better" lever in an arcade game.

**Cons:** Even placeholder SFX (free packs) is scope M1 doesn't currently budget for.

**Context:** Consider whether M1 needs at least placeholder hit/miss SFX to fairly judge aim feel, even before real sound design happens later.

**Depends on / blocked by:** M1 planning — decide whether placeholder audio is in scope for the go/no-go judgment.

---

## 7. Hit-testing precision spec (weak points, occlusion, overlapping dinos)

**What:** "Reticle-position vs. depth-tested on-screen dino bounds" (Premise 2) doesn't yet define: how weak-point sub-regions are hit-tested (separate bounding box? bone-attached hit region?), what happens when one dino occludes another, or how overlapping dinos resolve which one gets hit.

**Why:** Codex's outside-voice review flagged this as underspecified — it's exactly the kind of detail that's easy to hand-wave in a design doc and expensive to improvise mid-implementation once multiple dinos are on screen simultaneously (M3's raptor-crossing encounter, M5a's herd crossing).

**Pros:** A concrete spec here prevents ad hoc hit-testing decisions made under implementation pressure from becoming inconsistent across encounters.

**Cons:** Genuinely hard to fully spec before dinos exist to test against — some of this may need real prototyping, not more design-doc prose.

**Context:** Best resolved once M3's first dino exists and there's something real to test hit-testing against, rather than speculating further in the doc now.

**Depends on / blocked by:** M3 implementation — revisit once there's a real dino on screen to test edge cases against.

---

## 8. TestFlight success-metric validity (hardware-gated test population)

**What:** The Codex success criterion ("friends ask for another run") assumes friends have access to a DualSense/DualShock — Codex pointed out this pre-filters who can even participate in the test, potentially producing a falsely small or skewed signal.

**Why:** If most friends only own Xbox controllers, the "ask for another run" signal comes from a small, DualSense-owning subset — not a representative test of whether the game is fun.

**Pros:** Worth knowing before treating TestFlight feedback as validating (or invalidating) the whole design.

**Cons:** Not really fixable in this design — it's a fact about the DualSense-gyro requirement's actual reach, not a bug to solve.

**Context:** Consider owning/lending a couple of DualSense controllers to TestFlight friends specifically to widen the test population, or explicitly caveat any "friends loved it" signal as coming from a self-selected DualSense-owning group.

**Depends on / blocked by:** M5b / TestFlight rollout — a logistics note, not a design change.

---

## 9. Boss design decomposition (T-Rex, and future bosses)

**What:** "T-Rex boss (head/neck target)" in M5a isn't yet decomposed into phases, telegraphs, camera blocking, damage windows, or spectacle animation beats.

**Why:** Codex's outside-voice review noted a rail-shooter boss needs real structure (e.g. phase 1: telegraph → dodge-or-die window → weak point exposed → phase 2: faster/angrier) to feel like a boss rather than "a big target with more health."

**Pros:** Bosses are the single highest-visibility moment in the game — worth getting right rather than treating as "another encounter."

**Cons:** Real design iteration, likely needs actual playtesting against a graybox boss to get phase pacing right — not purely a spec-on-paper exercise.

**Context:** M5a's Next Steps entry already names "T-Rex boss (head/neck target, phased: telegraph → damage window → weak-point exposed → repeat, at minimum 2 phases)" as a starting structure — this TODO tracks the deeper design pass beyond that minimum.

**Depends on / blocked by:** M5a implementation — refine once the minimum 2-phase structure is playable.

---

## 10. UI scope (calibration, capability detection, per-player reticles, accessibility)

**What:** Calibration flow, controller-capability detection (does this pad have gyro or not?), per-player reticle rendering, pause/disconnect UI, and non-gyro-pad accessibility — collectively larger than "a debug HUD plus a start screen."

**Why:** Codex's outside-voice review flagged that the plan's UI mentions (debug tuning HUD in M1, start screen in M5b) understate the real UI surface area a shippable game needs.

**Pros:** Naming this now means it doesn't get discovered as a surprise mid-M5b.

**Cons:** Hard to size precisely without knowing exactly how many controller types need distinct UI treatment.

**Context:** Worth a dedicated UI pass during M5b planning rather than assuming it falls out of the start-screen work "for free."

**Depends on / blocked by:** M5b planning — size this explicitly before M5b implementation begins.

---

## 11. Legal/trade-dress framing beyond names and logos

**What:** Premise 7's "no Jurassic Park names/logos/music" protects against the most obvious IP risk, but Codex's outside-voice review pointed out that cloning specific staging (a raptor ambush in tall grass, a T-Rex boss fight, jeep/helicopter sequences) can still read as recognizable trade dress even with renamed assets.

**Why:** Worth a conscious "what must actually differ" list, not just a "don't use these names" list, especially since this project's whole premise is "clone it to a large extent."

**Pros:** A clearer sense of where the line is reduces ambiguity about what's safe for a private/friends-only build.

**Cons:** This is a personal project distributed only via TestFlight to friends, not commercially — the practical legal exposure is very low regardless; this is a "know where the line is" exercise, not a blocking legal review.

**Context:** Worth a brief pass (e.g., vary the specific staging beats, not just the names) before considering any distribution beyond friends — not before M0/M1.

**Depends on / blocked by:** Nothing blocking — informational, revisit only if distribution scope ever expands beyond friends.
