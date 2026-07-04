#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE_DIR="$ROOT_DIR/client/macos-native"
CONFIGURATION="${CONFIGURATION:-Release}"
ARCH="${ARCH:-$(uname -m)}"
DERIVED_DATA="$ROOT_DIR/dist-native/DerivedData"
APP_OUTPUT_DIR="$ROOT_DIR/dist-native"

case "$ARCH" in
  arm64|x86_64) ;;
  amd64) ARCH="x86_64" ;;
  *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
esac

mkdir -p "$APP_OUTPUT_DIR"

if command -v xcodegen >/dev/null 2>&1; then
  (cd "$NATIVE_DIR" && xcodegen generate)
else
  echo "xcodegen not found; using checked-in Xcode project"
fi

xcodebuild \
  -project "$NATIVE_DIR/VibeCodingPlusNative.xcodeproj" \
  -scheme VibeCodingPlusNative \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS,arch=$ARCH" \
  -derivedDataPath "$DERIVED_DATA" \
  build

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/VibeCoding Plus.app"
rm -rf "$APP_OUTPUT_DIR/VibeCoding Plus.app"
cp -R "$APP_PATH" "$APP_OUTPUT_DIR/VibeCoding Plus.app"

codesign --force --deep --sign - "$APP_OUTPUT_DIR/VibeCoding Plus.app"
ditto -c -k --keepParent "$APP_OUTPUT_DIR/VibeCoding Plus.app" "$APP_OUTPUT_DIR/VibeCoding Plus-native-${CONFIGURATION}-${ARCH}.zip"

echo "Native app built: $APP_OUTPUT_DIR/VibeCoding Plus.app"
echo "Native zip built: $APP_OUTPUT_DIR/VibeCoding Plus-native-${CONFIGURATION}-${ARCH}.zip"
