#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-debug}"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/MinusOne.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

swift build --disable-sandbox --package-path "$ROOT_DIR" -c "$CONFIGURATION"

# Refresh Liquid Glass catalog if missing or .icon is newer
if [[ ! -f "$ROOT_DIR/Resources/Assets.car" ]] \
  || [[ "$ROOT_DIR/Resources/MinusOne.icon/icon.json" -nt "$ROOT_DIR/Resources/Assets.car" ]]; then
  "$ROOT_DIR/Scripts/package-icon.sh"
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/Resources/Assets.car" "$RESOURCES_DIR/Assets.car"
[[ -f "$ROOT_DIR/Resources/MinusOne.icns" ]] && cp "$ROOT_DIR/Resources/MinusOne.icns" "$RESOURCES_DIR/MinusOne.icns"
cp "$ROOT_DIR/.build/$CONFIGURATION/MinusOne" "$MACOS_DIR/MinusOne"
chmod +x "$MACOS_DIR/MinusOne"

# Sparkle (in-app updates). SwiftPM leaves the framework next to the binary, but inside the bundle it
# lives in Contents/Frameworks, so the binary needs an rpath pointing there. ditto keeps the
# framework's internal symlinks, which cp -R would flatten.
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
SPARKLE_DIR="$FRAMEWORKS_DIR/Sparkle.framework"
mkdir -p "$FRAMEWORKS_DIR"
ditto "$ROOT_DIR/.build/$CONFIGURATION/Sparkle.framework" "$SPARKLE_DIR"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/MinusOne"
# The XPC services exist for sandboxed apps only; MinusOne isn't sandboxed.
rm -rf "$SPARKLE_DIR/Versions/B/XPCServices" "$SPARKLE_DIR/XPCServices"

# Seal the bundle. Prefer a local signing identity; fall back to ad-hoc.
# Note: GitHub downloads still need Developer ID + notarization for Gatekeeper to trust them.
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}')" || SIGN_ID=""

sign() {
  if [[ -n "$SIGN_ID" ]]; then
    codesign --force --options runtime --sign "$SIGN_ID" "$1"
  else
    codesign --force --sign - "$1"
  fi
}

# Inside-out, never --deep: --deep re-signs Sparkle's helpers without their own settings.
sign "$SPARKLE_DIR/Versions/B/Autoupdate"
sign "$SPARKLE_DIR/Versions/B/Updater.app"
sign "$SPARKLE_DIR"
sign "$APP_DIR"

echo "Built $APP_DIR"
codesign -dv --verbose=2 "$APP_DIR" 2>&1 | awk '/Authority|Signature|TeamIdentifier|flags=/{print}'
