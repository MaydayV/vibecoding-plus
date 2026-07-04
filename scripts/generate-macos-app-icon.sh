#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="$ROOT/client/macos-native/Resources/Assets.xcassets/AppIcon.appiconset"
SOURCE="${1:-$ROOT/client/macos-native/Resources/AppIconSources/Default/AppIcon-Default-1024.png}"

if [[ ! -f "$SOURCE" ]]; then
  echo "Missing icon source PNG: $SOURCE" >&2
  exit 1
fi

render() {
  local size="$1"
  local out="$ICONSET/AppIcon-${size}.png"
  if [[ "$size" -eq 1024 ]]; then
    cp "$SOURCE" "$out"
  elif command -v magick >/dev/null 2>&1; then
    magick "$SOURCE" -resize "${size}x${size}" -background none -gravity center -extent "${size}x${size}" "$out"
  elif command -v sips >/dev/null 2>&1; then
    cp "$SOURCE" "$out"
    sips -z "$size" "$size" "$out" >/dev/null
  else
    echo "magick or sips is required to resize icon PNGs" >&2
    exit 1
  fi
  echo "wrote $out"
}

for size in 16 32 64 128 256 512 1024; do
  render "$size"
done
