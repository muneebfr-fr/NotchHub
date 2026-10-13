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

# A rebuild changes the app's signature, which silently invalidates its old Accessibility entry.
# Clearing it lets the relaunched app show a fresh permission prompt.
tccutil reset Accessibility local.notchhub
pkill -x NotchHub || true
sleep 0.5
open "$APP"
