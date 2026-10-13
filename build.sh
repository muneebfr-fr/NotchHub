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
pkill -x NotchHub || true
sleep 0.5
open "$APP"
