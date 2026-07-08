#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

"$ROOT_DIR/Scripts/build-app.sh"
pkill 3mid-tab 2>/dev/null || true
rm -rf /Applications/3mid-tab.app
cp -R "$ROOT_DIR/build/3mid-tab.app" /Applications/3mid-tab.app
open /Applications/3mid-tab.app
