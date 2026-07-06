#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="3mid-tab"
APP="$ROOT_DIR/build/$APP_NAME.app"
STAGE="$ROOT_DIR/dist/dmg"
DMG="$ROOT_DIR/dist/$APP_NAME.dmg"

"$ROOT_DIR/Scripts/build-app.sh"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG"

echo "Built $DMG"
