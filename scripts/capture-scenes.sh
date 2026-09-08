#!/usr/bin/env bash
# Capture a fixed set of named moments as PNGs and assemble a contact sheet.
#
# Deliberately NOT a golden-image test. Pixel comparison across GPUs, drivers
# and OS versions is a false-failure sink, and CI's runner is not this Mac.
# The value is a human scanning one sheet after a visual change, plus cheap
# structural checks that catch a black frame or a failed draw.
#
# Usage: scripts/capture-scenes.sh [outdir]     (default .build/captures)
set -uo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-.build/captures}"
mkdir -p "$OUT"

xcodegen >/dev/null
xcodebuild -scheme Rex-macOS -destination 'platform=macOS' \
           -derivedDataPath .build/DerivedData \
           CODE_SIGNING_ALLOWED=NO build -quiet || exit 1
APP=".build/DerivedData/Build/Products/Debug/Rex-macOS.app/Contents/MacOS/Rex-macOS"
[ -x "$APP" ] || { echo "capture: app not built at $APP" >&2; exit 1; }

# A flat frame (failed draw) compresses to almost nothing; a real frame of this
# scene does not. Crude but dependency-free, and it catches the failure that
# actually happens — a black or single-colour drawable.
MIN_BYTES=40000

# name | extra env | seconds before the shot | auto-fire?
# The title screen must NOT auto-fire: a trigger pulse joins a player and
# starts the run, so the shot would land on gameplay instead of the title.
SCENES=(
  "title||1.5|no"
  "chase-wave|REX_CAPTURE_PLAY=1|3.0|yes"
  "chase-late|REX_CAPTURE_PLAY=1|6.5|yes"
  "arena-holdout|REX_CAPTURE_ARENA=1|3.0|yes"
)

fail=0
for scene in "${SCENES[@]}"; do
  IFS='|' read -r name extra after autofire <<< "$scene"
  fireflag=""; [ "$autofire" = "yes" ] && fireflag="--auto-fire"
  png="$OUT/$name.png"
  rm -f "$png"

  # MUST be backgrounded. Launched in the foreground from a non-interactive
  # shell the app never acquires a drawable, so drawInMTKView early-returns,
  # the world never ticks, and the capture writes nothing. It exits itself
  # ~2.5s after taking the shot.
  # shellcheck disable=SC2086
  ( env -u DYLD_LIBRARY_PATH REX_MUTE=1 $extra "$APP" \
        --capture-out="$png" --capture-after="$after" $fireflag >/dev/null 2>&1 ) &
  pid=$!
  waited=0
  limit=$(printf '%.0f' "$(echo "$after" | awk '{print $1 + 12}')")
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$limit" ]; do sleep 1; waited=$((waited+1)); done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

  if [ ! -s "$png" ]; then
    echo "capture: MISSING  $name"; fail=1; continue
  fi
  bytes=$(stat -f%z "$png")
  dims=$(sips -g pixelWidth -g pixelHeight "$png" 2>/dev/null | awk '/pixel/{printf "%s ", $2}')
  if [ "$bytes" -lt "$MIN_BYTES" ]; then
    echo "capture: FLAT?    $name  (${bytes}B — suspiciously small, likely a failed draw)"; fail=1
  else
    echo "capture: ok       $name  (${dims%  }, ${bytes}B)"
  fi
done

if command -v montage >/dev/null 2>&1; then
  montage -label '%t' "$OUT"/[a-z]*.png -tile 2x -geometry +4+4 \
          -background '#222' -fill white -pointsize 28 "$OUT/contact-sheet.png" 2>/dev/null \
    && echo "capture: contact sheet -> $OUT/contact-sheet.png"
else
  echo "capture: (brew install imagemagick for a contact sheet)"
fi
exit $fail
