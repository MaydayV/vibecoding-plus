#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="$ROOT/client/macos-native/Resources/Assets.xcassets/AppIcon.appiconset"
SOURCE="${1:-$ROOT/client/macos-native/Resources/AppIconSources/Default/AppIcon-Default-1024.png}"
# Designer exports often fill the canvas; scale down to match system icon size.
INSET_PERCENT="${ICON_INSET_PERCENT:-85}"

if [[ ! -f "$SOURCE" ]]; then
  echo "Missing icon source PNG: $SOURCE" >&2
  exit 1
fi

if ! command -v magick >/dev/null 2>&1; then
  echo "ImageMagick (magick) is required to inset macOS app icons" >&2
  exit 1
fi

MASTER="$(mktemp /tmp/vcp-icon-master.XXXXXX).png"
trap 'rm -f "$MASTER"' EXIT

magick "$SOURCE" -resize "${INSET_PERCENT}%" -background none -gravity center -extent 1024x1024 PNG32:"$MASTER"

render() {
  local size="$1"
  local out="$ICONSET/AppIcon-${size}.png"
  magick "$MASTER" -resize "${size}x${size}" PNG32:"$out"
  echo "wrote $out"
}

for size in 16 32 64 128 256 512 1024; do
  render "$size"
done

echo "Inset ${INSET_PERCENT}% (transparent padding) from $SOURCE"
