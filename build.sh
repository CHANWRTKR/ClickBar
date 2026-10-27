#!/bin/zsh
set -eu
PROJECT_DIR="${0:A:h}"
OUTPUT_DIR="${1:-$PROJECT_DIR/dist}"
cd "$PROJECT_DIR"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP_DIR="$OUTPUT_DIR/ClickBar.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/ClickBar" "$APP_DIR/Contents/MacOS/ClickBar"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/*LICENSE.txt "$APP_DIR/Contents/Resources/"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP_DIR"
codesign --verify --strict "$APP_DIR"
print "Built: $APP_DIR"
