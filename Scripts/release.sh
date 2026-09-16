#!/usr/bin/env bash
set -euo pipefail

# Builds everything a release needs: the dmg for manual installs, plus the signed zip and
# appcast.xml the in-app updater reads. Never touches GitHub.
#
# Usage: Scripts/release.sh <version> [--local]   e.g. Scripts/release.sh 0.7.0
#
# Before running: bump CFBundleShortVersionString to <version> and increment CFBundleVersion in
# Resources/Info.plist (Sparkle compares CFBundleVersion), and write build/release-notes-v<version>.md.
# Signing reads the private EdDSA key from the login Keychain (created once with generate_keys).
#
# MINUSONE_DOWNLOAD_BASE overrides where the appcast points users to download the update from.
# It must be an https:// URL unless you pass --local (e.g. for testing against a local file server),
# since anything else would ship an appcast pointing every user's updater at a non-production host.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:?Usage: Scripts/release.sh <version>}"
ALLOW_LOCAL="${2:-}"
BUILD_DIR="$ROOT_DIR/build"
PLIST="$ROOT_DIR/Resources/Info.plist"
PB=/usr/libexec/PlistBuddy
SIGN_UPDATE="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update"
NOTES="$BUILD_DIR/release-notes-v$VERSION.md"

PLIST_VERSION="$($PB -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD_NUMBER="$($PB -c 'Print :CFBundleVersion' "$PLIST")"
MIN_OS="$($PB -c 'Print :LSMinimumSystemVersion' "$PLIST")"

if [[ "$PLIST_VERSION" != "$VERSION" ]]; then
  echo "Info.plist says $PLIST_VERSION, not $VERSION. Bump the version first." >&2
  exit 1
fi
if [[ ! -f "$NOTES" ]]; then
  echo "Missing release notes: $NOTES" >&2
  exit 1
fi

DOWNLOAD_BASE="${MINUSONE_DOWNLOAD_BASE:-https://github.com/cro64/MinusOne/releases/download/v$VERSION}"
if [[ "$DOWNLOAD_BASE" != https://* && "$ALLOW_LOCAL" != "--local" ]]; then
  echo "MINUSONE_DOWNLOAD_BASE is '$DOWNLOAD_BASE', which is not an https:// URL." >&2
  echo "Refusing to publish an appcast that would point users' updaters at it." >&2
  echo "For local testing, pass --local as the second argument: Scripts/release.sh $VERSION --local" >&2
  exit 1
fi

"$ROOT_DIR/Scripts/build-app.sh" release
if [[ ! -x "$SIGN_UPDATE" ]]; then
  echo "Missing $SIGN_UPDATE (Sparkle's tools come with swift build)." >&2
  exit 1
fi
"$ROOT_DIR/Scripts/package-dmg.sh"

ZIP_NAME="MinusOne-v$VERSION-macos.zip"
ZIP="$BUILD_DIR/$ZIP_NAME"
DMG="$BUILD_DIR/MinusOne-v$VERSION-macos.dmg"
APPCAST="$BUILD_DIR/appcast.xml"

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$BUILD_DIR/MinusOne.app" "$ZIP"

# Prints: sparkle:edSignature="…" length="…"
SIGNATURE_ATTRS="$("$SIGN_UPDATE" "$ZIP")"

# Sparkle shows embedded notes as plain text, so drop Markdown marks that would show literally.
NOTES_TEXT="$(sed -e 's/\*\*//g' -e 's/`//g' -e 's/^#\{1,6\} //' "$NOTES")"
if [[ "$NOTES_TEXT" == *"]]>"* ]]; then
  echo "Release notes contain ']]>', which would break the appcast." >&2
  exit 1
fi

cat > "$APPCAST" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>MinusOne</title>
    <item>
      <title>MinusOne $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <description sparkle:descriptionFormat="plain-text"><![CDATA[$NOTES_TEXT]]></description>
      <enclosure url="$DOWNLOAD_BASE/$ZIP_NAME" $SIGNATURE_ATTRS type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF

xmllint --noout "$APPCAST"

echo
echo "Attach all three to the GitHub release v$VERSION:"
ls -lh "$DMG" "$ZIP" "$APPCAST"
echo
echo "Update will be fetched from: $DOWNLOAD_BASE/$ZIP_NAME"
echo "sparkle:version written to appcast: $BUILD_NUMBER"
echo
echo "Every release must include appcast.xml: the app reads it from whichever release is marked latest."
