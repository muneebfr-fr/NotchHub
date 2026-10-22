#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/NotchHub.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/NotchHub "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "Built $APP"

# GlassDock is a separate app in this repo; rebuild it only when its sources changed (its rebuild resets
# its permissions, so skipping unchanged builds avoids needless prompts).
GLASSDOCK=GlassDock/build/GlassDock.app/Contents/MacOS/GlassDock
if [ ! -f "$GLASSDOCK" ] || [ -n "$(find GlassDock/Sources GlassDock/Package.swift GlassDock/Info.plist -newer "$GLASSDOCK" 2>/dev/null)" ]; then
    ./GlassDock/build.sh
    # A running GlassDock is restarted on the new build by NotchHub's watchdog.
    pkill -x GlassDock || true
fi

# A rebuild changes the app's signature, which silently invalidates its old permission entries.
# Clearing them lets the relaunched app show fresh permission prompts.
tccutil reset Accessibility local.notchhub
tccutil reset ScreenCapture local.notchhub
tccutil reset AudioCapture local.notchhub || true
pkill -x NotchHub || true
sleep 0.5
open "$APP"
