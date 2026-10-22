#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/GlassDock.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/GlassDock "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "Built $APP"
# Rebuilds change the signature, so stale permission entries are cleared for fresh prompts.
tccutil reset Accessibility local.glassdock || true
tccutil reset ScreenCapture local.glassdock || true
