#!/usr/bin/env bash
# Builds LiteMux.app from the SwiftPM package (arm64, release) and ad-hoc signs it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
ARCH="${ARCH:-arm64}"
OUT="${OUT:-$ROOT/build}"
APP="$OUT/LiteMux.app"

cd "$ROOT"
swift build -c "$CONFIG" --arch "$ARCH" -Xswiftc -Osize
BIN="$(swift build -c "$CONFIG" --arch "$ARCH" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/LiteMux" "$APP/Contents/MacOS/LiteMux"
strip -rSTx "$APP/Contents/MacOS/LiteMux" 2>/dev/null || strip -x "$APP/Contents/MacOS/LiteMux"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon: build AppIcon.icns from the 1024px master if iconutil is available.
if [[ -f Resources/AppIcon.png ]] && command -v iconutil >/dev/null; then
  ICONSET="$OUT/AppIcon.iconset"
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi

# SwiftPM resource bundles, if any dependency ships one.
find "$BIN" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;

codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"
