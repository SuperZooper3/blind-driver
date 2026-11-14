#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
godot_bin="${GODOT:-godot}"
version="$("$godot_bin" --version)"
if [[ "$version" != 4.7.2.stable.* ]]; then
  echo "Web builds require Godot 4.7.2 stable and matching export templates; found $version" >&2
  exit 1
fi
mkdir -p build/web
"$godot_bin" --headless --path . --editor --import
"$godot_bin" --headless --path . --export-release Web build/web/game.html
cp frontend/launcher.js frontend/style.css frontend/favicon.svg build/web/
mkdir -p build/web/media
cp frontend/media/*.png build/web/media/
# Precompress once during the build, so serving the large engine is inexpensive.
node frontend/compress.mjs build/web
