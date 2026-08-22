#!/bin/bash
set -euo pipefail

APP_NAME="SerialKeyboardBridge"
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/.build/release"
APP_BUNDLE="$ROOT/$APP_NAME.app"
INSTALL_DIR="${HOME}/Applications"

echo "Building release…"
cd "$ROOT"
swift build -c release

echo "Creating app bundle…"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$ROOT/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

echo "Installing to ${INSTALL_DIR}…"
mkdir -p "$INSTALL_DIR"
rm -rf "${INSTALL_DIR}/${APP_NAME}.app"
ditto "$APP_BUNDLE" "${INSTALL_DIR}/${APP_NAME}.app"

echo "Done: ${INSTALL_DIR}/${APP_NAME}.app"
echo "Launch from Applications or Spotlight: Serial Keyboard Bridge"
