#!/bin/bash
# Builds build/GroundhogZ.app (no Xcode project needed).
set -euo pipefail
cd "$(dirname "$0")"

APP=build/GroundhogZ.app
BIN=$APP/Contents/MacOS/GroundhogZ
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling..."
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
  -framework Metal -framework MetalKit -framework AppKit -framework AVFoundation \
  Sources/*.swift -o "$BIN"

cp Info.plist "$APP/Contents/Info.plist"

echo "Making icon..."
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
"$BIN" --icon build/icon_1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
