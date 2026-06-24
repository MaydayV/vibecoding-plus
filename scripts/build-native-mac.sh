#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE_DIR="$ROOT_DIR/client/macos-native"
CONFIGURATION="${CONFIGURATION:-Release}"
NODE_VERSION="${NODE_VERSION:-22.21.1}"
ARCH="${ARCH:-$(uname -m)}"
DERIVED_DATA="$ROOT_DIR/dist-native/DerivedData"
APP_OUTPUT_DIR="$ROOT_DIR/dist-native"

case "$ARCH" in
  arm64) NODE_ARCH="arm64" ;;
  x86_64|amd64) NODE_ARCH="x64" ;;
  *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
esac

NODE_NAME="node-v${NODE_VERSION}-darwin-${NODE_ARCH}"
NODE_TARBALL="${NODE_NAME}.tar.gz"
NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TARBALL}"
NODE_CACHE="$ROOT_DIR/.npm-cache/native-node/$NODE_TARBALL"
NODE_UNPACK_DIR="$ROOT_DIR/.npm-cache/native-node/$NODE_NAME"

mkdir -p "$APP_OUTPUT_DIR" "$(dirname "$NODE_CACHE")"

if command -v xcodegen >/dev/null 2>&1; then
  (cd "$NATIVE_DIR" && xcodegen generate)
else
  echo "xcodegen not found; using checked-in Xcode project"
fi

if [[ ! -d "$NODE_UNPACK_DIR" ]]; then
  if [[ ! -f "$NODE_CACHE" ]]; then
    echo "Downloading $NODE_URL"
    curl -fL "$NODE_URL" -o "$NODE_CACHE"
  fi
  rm -rf "$NODE_UNPACK_DIR"
  tar -xzf "$NODE_CACHE" -C "$(dirname "$NODE_UNPACK_DIR")"
fi

xcodebuild \
  -project "$NATIVE_DIR/VibeCodingPlusNative.xcodeproj" \
  -scheme VibeCodingPlusNative \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS,arch=$ARCH" \
  -derivedDataPath "$DERIVED_DATA" \
  build

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/VibeCoding Plus.app"
RUNTIME_DIR="$APP_PATH/Contents/Resources/runtime"

rm -rf "$RUNTIME_DIR"
mkdir -p "$RUNTIME_DIR/client" "$RUNTIME_DIR/node_modules"

rsync -a --delete \
  --exclude '.DS_Store' \
  --exclude 'test' \
  "$ROOT_DIR/client/server" "$RUNTIME_DIR/client/"

rsync -a --delete \
  "$ROOT_DIR/node_modules/ws" "$RUNTIME_DIR/node_modules/"

cp "$ROOT_DIR/package.json" "$RUNTIME_DIR/package.json"
rsync -a --delete "$NODE_UNPACK_DIR/" "$RUNTIME_DIR/node/"

rm -rf "$APP_OUTPUT_DIR/VibeCoding Plus.app"
cp -R "$APP_PATH" "$APP_OUTPUT_DIR/VibeCoding Plus.app"

codesign --force --deep --sign - "$APP_OUTPUT_DIR/VibeCoding Plus.app"
ditto -c -k --keepParent "$APP_OUTPUT_DIR/VibeCoding Plus.app" "$APP_OUTPUT_DIR/VibeCoding Plus-native-${CONFIGURATION}-${ARCH}.zip"

echo "Native app built: $APP_OUTPUT_DIR/VibeCoding Plus.app"
echo "Native zip built: $APP_OUTPUT_DIR/VibeCoding Plus-native-${CONFIGURATION}-${ARCH}.zip"
echo "Bundled node: $("$APP_OUTPUT_DIR/VibeCoding Plus.app/Contents/Resources/runtime/node/bin/node" -v)"
