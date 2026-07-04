#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="$ROOT/client/macos-native/Resources/Assets.xcassets/AppIcon.appiconset"
SVG="$ICONSET/AppIcon.svg"

if [[ ! -f "$SVG" ]]; then
  echo "Missing icon source: $SVG" >&2
  exit 1
fi

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "rsvg-convert is required (brew install librsvg)" >&2
  exit 1
fi

render() {
  local size="$1"
  local out="$ICONSET/AppIcon-${size}.png"
  rsvg-convert -w "$size" -h "$size" "$SVG" -o "$out"
  if command -v magick >/dev/null 2>&1; then
    magick "$out" -background "#FCFAF3" -alpha remove -alpha off "$out"
  fi
  echo "wrote $out"
}

for size in 16 32 64 128 256 512 1024; do
  render "$size"
done
