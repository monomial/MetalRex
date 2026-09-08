#!/usr/bin/env bash
# Record the game playing itself, and assemble it into a watchable clip.
#
# Why: every "does this feel right?" question in this project — aim tracking,
# the weak-point tint, the attack tell's lead, the hit flash — is about
# MOTION. A headless test cannot see it and a still frame cannot show it.
# This drives a real run through the normal input path (--autopilot, see
# Simulation/Systems/AutopilotSystem.h) and writes an mp4 you can watch.
#
# Frames are paced by SIM time, not wall time: the app runs with a fixed
# per-frame dt of 1/fps while capturing, so a slow PNG encode stretches how
# long the capture takes without stretching the clip. 20 seconds of clip is
# 20 seconds of game, on any machine.
#
# Usage: scripts/capture-clip.sh [seconds] [outdir]     (default 20s, .build/clips)
set -uo pipefail
cd "$(dirname "$0")/.."

SECONDS_WANTED="${1:-20}"
OUT="${2:-.build/clips}"
FPS=30
SIZE=1280x720
FRAMES=$(( SECONDS_WANTED * FPS ))

command -v ffmpeg >/dev/null || { echo "clip: needs ffmpeg (brew install ffmpeg)" >&2; exit 1; }

rm -rf "$OUT/frames"
mkdir -p "$OUT/frames"

xcodegen >/dev/null
xcodebuild -scheme Rex-macOS -destination 'platform=macOS' \
           -derivedDataPath .build/DerivedData \
           CODE_SIGNING_ALLOWED=NO build -quiet || exit 1
APP=".build/DerivedData/Build/Products/Debug/Rex-macOS.app/Contents/MacOS/Rex-macOS"
[ -x "$APP" ] || { echo "clip: app not built at $APP" >&2; exit 1; }

echo "clip: recording ${SECONDS_WANTED}s (${FRAMES} frames at ${FPS}fps, ${SIZE})"

# MUST be backgrounded: launched in the foreground from a non-interactive
# shell the app never acquires a drawable, so the world never ticks and
# nothing is written (the same trap scripts/capture-scenes.sh documents).
# The capture starts at the TITLE and the bot joins itself, so the clip
# opens on the title card exactly as a player would see it.
( env -u DYLD_LIBRARY_PATH REX_MUTE=1 "$APP" \
      --autopilot \
      --capture-clip="$PWD/$OUT/frames" \
      --capture-frames="$FRAMES" \
      --capture-fps="$FPS" \
      --capture-size="$SIZE" >/dev/null 2>&1 ) &
pid=$!

# Wall-clock budget: the PNG encoder is the bottleneck, so allow well over
# real time, plus a floor for build/launch overhead.
limit=$(( SECONDS_WANTED * 6 + 60 ))
waited=0
while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$limit" ]; do
  sleep 2; waited=$((waited+2))
  written=$(ls "$OUT/frames" 2>/dev/null | wc -l | tr -d ' ')
  printf '\rclip: %s/%s frames' "$written" "$FRAMES"
done
printf '\n'
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

written=$(ls "$OUT/frames"/frame-*.png 2>/dev/null | wc -l | tr -d ' ')
if [ "$written" -lt 2 ]; then
  echo "clip: FAILED — only $written frames written" >&2
  exit 1
fi
if [ "$written" -lt "$FRAMES" ]; then
  echo "clip: WARNING — $written of $FRAMES frames (capture was cut short)" >&2
fi

MP4="$OUT/run.mp4"
GIF="$OUT/run.gif"
ffmpeg -y -loglevel error -framerate "$FPS" -i "$OUT/frames/frame-%05d.png" \
       -c:v libx264 -pix_fmt yuv420p -crf 20 "$MP4" || exit 1

# A GIF too, for pasting where video will not go. Half rate and half size —
# a full-rate 720p GIF is tens of megabytes and nobody opens it.
ffmpeg -y -loglevel error -framerate "$FPS" -i "$OUT/frames/frame-%05d.png" \
       -vf "fps=15,scale=640:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse" \
       "$GIF" 2>/dev/null

echo "clip: $written frames -> $MP4 ($(du -h "$MP4" | cut -f1))"
[ -s "$GIF" ] && echo "clip: $GIF ($(du -h "$GIF" | cut -f1))"
