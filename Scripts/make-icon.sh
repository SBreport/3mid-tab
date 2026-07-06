#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$ROOT_DIR/Assets/app-icon.svg"
SOURCE="$ROOT_DIR/Assets/app-icon-source.png"
ICONSET="$ROOT_DIR/Assets/AppIcon.iconset"
ICNS="$ROOT_DIR/Assets/AppIcon.icns"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

rm -rf "$ROOT_DIR/Assets/app-icon-source.png" "$ROOT_DIR/Assets/app-icon.svg.png"
qlmanage -t -s 1024 -o "$ROOT_DIR/Assets" "$SVG" >/dev/null 2>&1
mv "$ROOT_DIR/Assets/app-icon.svg.png" "$SOURCE"

sips -z 16 16     "$SOURCE" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32     "$SOURCE" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "$SOURCE" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64     "$SOURCE" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "$SOURCE" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256   "$SOURCE" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$SOURCE" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512   "$SOURCE" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$SOURCE" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$SOURCE" --out "$ICONSET/icon_512x512@2x.png" >/dev/null

iconutil -c icns "$ICONSET" -o "$ICNS"
echo "Built $ICNS"
