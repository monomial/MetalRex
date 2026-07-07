#!/usr/bin/env bash
# Build the macOS app and launch it briefly to catch startup crashes.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${1:-}" = "--autotest" ]; then
  xcodegen
  xcodebuild -scheme RexLogicTests \
             -destination 'platform=macOS' \
             -derivedDataPath .build/DerivedData \
             test -quiet
  exit $?
fi

xcodegen
xcodebuild -scheme Rex-macOS \
           -destination 'platform=macOS' \
           -derivedDataPath .build/DerivedData \
           build -quiet

xcodebuild -scheme RexLogicTests \
           -destination 'platform=macOS' \
           -derivedDataPath .build/DerivedData \
           test -quiet

APP=".build/DerivedData/Build/Products/Debug/Rex-macOS.app/Contents/MacOS/Rex-macOS"

# Clear DYLD_LIBRARY_PATH — inherited from Node it confuses the dynamic linker.
set +e
env -u DYLD_LIBRARY_PATH REX_MUTE=1 "$APP" &
pid=$!
sleep 3
kill "$pid" >/dev/null 2>&1
wait "$pid" >/dev/null 2>&1
status=$?
set -e

if [ "$status" -eq 0 ] || [ "$status" -eq 143 ] || [ "$status" -eq 15 ]; then
  echo "smoke: launch ok"
  exit 0
fi

echo "smoke: launch exited with status $status"
exit "$status"
