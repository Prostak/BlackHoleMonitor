#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="${HOME}/Applications"
APP_NAME="Bhm_12.app"
DEST="${INSTALL_DIR}/${APP_NAME}"

cd "$ROOT"

echo "Building Release (macOS 12+, universal arm64+x86_64)…"
xcodebuild \
  -project BlackHoleMonitor.xcodeproj \
  -scheme BlackHoleMonitor \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  MACOSX_DEPLOYMENT_TARGET=12.0 \
  clean build \
  CODE_SIGN_IDENTITY="-" \
  >/dev/null

BUILT_APP="$(find "${HOME}/Library/Developer/Xcode/DerivedData"/BlackHoleMonitor-*/Build/Products/Release -name "$APP_NAME" -maxdepth 1 | head -1)"

if [[ -z "$BUILT_APP" || ! -d "$BUILT_APP" ]]; then
  echo "Could not find built app in DerivedData." >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"
rm -rf "$DEST"
ditto "$BUILT_APP" "$DEST"
touch "$DEST"
touch "$DEST/Contents/MacOS/Bhm_12"

echo "Installed: $DEST"
echo "Modified: $(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$DEST")"
echo "Architectures: $(lipo -archs "$DEST/Contents/MacOS/Bhm_12" 2>/dev/null || true)"
echo "Min OS: $(defaults read "$DEST/Contents/Info" LSMinimumSystemVersion 2>/dev/null || true)"
echo ""
echo "Next steps:"
echo "  1. Open: open \"$DEST\""
echo "  2. Copy to Air 2015: scp/AirDrop \"$DEST\" then right-click → Open (Gatekeeper)"
echo "  3. Accessibility (required after every reinstall):"
echo "     System Preferences → Security & Privacy → Privacy → Accessibility"
echo "     Remove Bhm_12 (−), then add again (+)"
echo "  4. Screen Recording (Battle / Autobattle):"
echo "     System Preferences → Security & Privacy → Privacy → Screen Recording → enable Bhm_12"
echo ""
echo "Use this installed copy instead of Xcode ⌘R."
