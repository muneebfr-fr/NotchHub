#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/EdgeShelf.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/EdgeShelf "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "Built $APP"
