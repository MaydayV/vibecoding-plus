#!/usr/bin/env bash
# Install the Release build to /Applications so Accessibility authorization
# stays tied to a stable path (still re-authorize after each rebuild if ad-hoc signed).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT_DIR/dist-native/VibeCoding Plus.app"
DEST="/Applications/VibeCoding Plus.app"

if [[ ! -d "$SRC" ]]; then
  echo "Missing $SRC — run: npm run native:dist:mac" >&2
  exit 1
fi

pkill -f "VibeCoding Plus" 2>/dev/null || true
sleep 1
rm -rf "$DEST"
ditto "$SRC" "$DEST"
xattr -cr "$DEST" 2>/dev/null || true
touch "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" 2>/dev/null || true

echo "Installed: $DEST"
echo ""
echo "Next: System Settings → Privacy & Security → Accessibility"
echo "  1. Remove any old「VibeCoding Plus」entries"
echo "  2. Click + and add: $DEST"
echo "  3. Launch from Applications (not an old DerivedData copy)"
echo ""
open -a "VibeCoding Plus" || open "$DEST"
