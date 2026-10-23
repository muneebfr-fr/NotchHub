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

# A rebuild changes the app's signature, which silently invalidates its old permission entries.
# Clearing them lets the relaunched app show fresh permission prompts.
tccutil reset Accessibility local.notchhub
tccutil reset ScreenCapture local.notchhub
tccutil reset AudioCapture local.notchhub || true
pkill -x NotchHub || true
sleep 0.5
open "$APP"

# GlassDock and Edge Shelf are separate apps in this repo; each is rebuilt only when its sources changed
# (a rebuild resets its permissions, so skipping unchanged builds avoids needless prompts). A running one is
# restarted on the new build by NotchHub's watchdog.
for APPNAME in GlassDock EdgeShelf; do
    BIN="$APPNAME/build/$APPNAME.app/Contents/MacOS/$APPNAME"
    if [ ! -f "$BIN" ] || [ -n "$(find "$APPNAME/Sources" "$APPNAME/Package.swift" "$APPNAME/Info.plist" -newer "$BIN" 2>/dev/null)" ]; then
        "./$APPNAME/build.sh"
        pkill -x "$APPNAME" || true
    fi
done
