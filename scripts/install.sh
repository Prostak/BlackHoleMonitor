#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="${HOME}/Applications"
APP_NAME="BlackHoleMonitor.app"
DEST="${INSTALL_DIR}/${APP_NAME}"

cd "$ROOT"

echo "Building Release (clean)…"
xcodebuild \
  -project BlackHoleMonitor.xcodeproj \
  -scheme BlackHoleMonitor \
  -configuration Release \
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
touch "$DEST/Contents/MacOS/BlackHoleMonitor"

echo "Installed: $DEST"
echo "Modified: $(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$DEST")"
echo ""
echo "Next steps:"
echo "  1. Open: open \"$DEST\""
echo "  2. Accessibility (required after every reinstall):"
echo "     System Settings → Privacy & Security → Accessibility"
echo "     Remove BlackHoleMonitor (−), then add the app again (+) or approve on first launch"
echo ""
echo "Use this installed copy instead of Xcode ⌘R."
