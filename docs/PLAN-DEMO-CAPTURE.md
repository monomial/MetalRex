# Demo autopilot + clip capture

**Status: implemented 2026-09-07.** Commits listed in the record below.

## The problem this solves

Every open question about this game is a question about MOTION: does the
reticle track the way a hand expects, does the weak-point tint read at
speed, does the attack tell lead the lunge by enough, does the hit flash
land. None of it survives the two tools this project had:

- the headless suite (123 tests) never renders a pixel;
- `scripts/capture-scenes.sh` renders four stills, and a still cannot show
  tracking, timing, or feel.

So the entire "does it feel right" category was unverifiable by anyone —
which, for a project whose owner does not have time to sit down and play a
build after each change, means unverifiable at all.

## What was built

**1. A demo autopilot** (`RexEngine/Simulation/Systems/AutopilotSystem.{h,mm}`)

Composes one tick of player input from the live world. It aims through the
stick, exactly like a player: it never writes `reticle.x/y`, never calls a
system directly, never reaches past `InputState`. An autopilot that
teleported the reticle would prove nothing about the aiming it exists to
demonstrate — the same reasoning `ScriptedInput` was built on.

Priorities, in order: the boss QTE's live points; any dino whose interrupt
window is open (the game's actual skill expression); otherwise the
front-most target, because since 3e64496 that is who the bullet hits, and
aiming behind it is firing into a shield. It takes weak points when the
animal exposes one, holds a committed target rather than jittering between
two equally close raptors, and re-centers when the field is empty. Title,
grade screen and continue prompt are all edge-gated on a fire release, so
those states pulse the trigger instead of holding it.

Enabled with `--autopilot` (macOS), which makes `RexGameHost` compose
player 0's input every frame, overriding the platform layer.

**2. Clip capture** (`--capture-clip=<dir> --capture-frames --capture-fps
--capture-size`)

Writes every drawn frame as a PNG. Two details carry it:

- **Frames are paced by SIM time, not wall time.** The host sets
  `fixedFrameDt = 1/fps` while recording, so each drawn frame advances
  exactly one frame of simulation no matter how long the PNG encode took.
  20 seconds of clip is 20 seconds of game, on any machine, reproducibly —
  rather than a recording of how fast this Mac happened to run.
- **The render loop stalls itself when writes fall behind.** The in-flight
  semaphore is signalled by an earlier completion handler than the one that
  writes the PNG, so nothing in the normal loop waits for encoding; without
  a stall, a long capture retains an unbounded queue of full-drawable
  staging buffers. `RexRenderer.pendingCaptureWrites` exposes the depth and
  the host spins on it. Stalling costs wall-clock time and no sim time,
  which is exactly the right currency to spend.

**3. `scripts/capture-clip.sh`** — builds, records, and assembles an mp4
(plus a smaller gif) with ffmpeg. `scripts/capture-clip.sh 60` covers a
whole act.

**4. `RexLogicTests/AutopilotTests.mm`** — five tests, and the project's
first true soak: one that plays an entire act unattended, so a wave that
never clears or a boss that never resolves fails in CI rather than in front
of a person.

## What the soak found immediately: the act could not be completed

The very first soak run failed, and the bug was real and total:

**The rail looped, so the act restarted forever.** `RailCameraSystem`
fmod-wrapped the camera back to distance 0 at the end of the rail and reset
the chart event index — behaviour its own comment called a placeholder ("a
real level (M5+) will end the act instead of looping"). But the act now has
an ending, and that ending is unreachable behind the loop:

- the level-ending QTE (`trex-qte-3-final`) is authored at rail distance
  31.5, near the end of a ~36-unit rail;
- a QTE **defers** while any raptor is alive, and `final-pack` is authored
  at 31.0, right in front of it;
- so the wrap always arrived before the last raptor died, the event index
  reset, and the act started over — with `scripted_major_attacks_done`
  saturating at 3/3 from re-fired earlier QTEs, which made the counter look
  finished while `isFinal` had never once been true.

Nothing caught this because no test had ever played a whole act. Every
existing arena and grade-screen test reaches those states by calling
`enter_arena()` directly.

**Fix:** the rail ends. `camera.distance` clamps at the rail's length and
`camera.speed` goes to 0 — the same stationary state `World::enter_arena`
already uses for the post-boss holdout, so it is well-trodden machinery
rather than a new mode. The old objection to clamping (a hang in
`update_targets`) no longer applies: that recycle/pin block is
straight-line, one assignment always lands in range. The wrap machinery and
its two tests are gone with it; `test_railEndStopsTheJeepAndKeepsChartProgress`
and `test_railEndPreservesPursuerGaps` cover the new contract, including
that the chart index only ever advances.

With that, a full run is: title -> chase -> 3 boss QTEs -> boss flees ->
3 arena waves -> LEVEL COMPLETE, grade B, in ~53 seconds.

## The second finding: the interrupt mechanic is unreachable by an accurate player

Instrumented across a whole act, the bot sees **19 ticks — 0.16 seconds —
of open interrupt window**, 10 ticks of Tell and 20 of Attack. It finishes
with 95% accuracy and **0 interrupts**, which the grade screen prints in
so many words.

The cause is not the bot. A raptor takes 3 shots, and anyone shooting
accurately kills it during Approach; it never reaches the lunge whose
denial is the scoring system the design doc calls the point of the game.
Recorded, not fixed — whether that is a problem is a design call (raptor
health is already derived from a "fair shooting window", so preemptive
killing may be intended), and it is the kind of call worth making against
a clip rather than a paragraph.

Consequently the bot's interrupt priority is proven directly, by handing it
one lunging dino and one closer, front-most approaching dino and asserting
which way it steers — not by hoping an act produces the situation.

## Verification

Every new test was mutation-tested rather than trusted green:

| mutation | caught by |
|---|---|
| rail clamps but the jeep does not stop | `test_railEndStopsTheJeepAndKeepsChartProgress` |
| restore the fmod loop | soak + both rail tests + play-again test |
| bot ignores the interrupt window | `test_botPrefersTheDinoWhoseInterruptWindowIsOpen` |
| bot's steering does nothing | 3 tests including the soak |

And the clip itself was verified by LOOKING at its frames, not by the
script's exit code — the lesson from the last capture work, where four
files reported `capture: ok` and were all the wrong scene. The 60-second
clip shows: title with 1 PLAYER selected, score and streak climbing, the
T-Rex QTE with the boss health bar draining through its rage colours, HOLD
OUT waves 2/3 and 3/3 in the arena interior, the grade panel (B, 2305,
95%, best streak x25, 43 weak points, 0 interrupts), and the next run
starting.

One thing the first clip caught: the macOS tuning HUD defaults ON and sat
over every frame. Clip capture now forces it off.

## Explicitly out of scope

- Pixel-comparison of clips in CI. Same reasoning as the contact sheet:
  cross-GPU comparison is a false-failure sink.
- Making the autopilot play *well* (it is a competent demo player, not an
  optimum), or tuning any gameplay constant to suit it.
- Fixing the interrupt-reachability finding. Recorded above for a design
  decision.
- tvOS capture. The clip path is macOS-only.
