#!/usr/bin/env bash
set -euo pipefail

# A stale or mismatched appcast breaks updates for every installed copy of MinusOne, and
# nothing else in the release pipeline fails loudly when that happens (an aborted release.sh
# run can leave an old appcast.xml describing a zip that no longer matches it). This script is
# the loud check: it re-derives everything an installed app's Sparkle updater would check
# before trusting an update, and fails hard if any of it does not line up.
#
# Usage: Scripts/verify-appcast.sh <appcast.xml> <zip> <public-key-base64>
# Exits 0 only if the appcast has exactly one enclosure, its length matches the zip's real
# size, and its sparkle:edSignature verifies against the given Ed25519 public key.

APPCAST="${1:?Usage: Scripts/verify-appcast.sh <appcast.xml> <zip> <public-key-base64>}"
ZIP="${2:?Usage: Scripts/verify-appcast.sh <appcast.xml> <zip> <public-key-base64>}"
PUBKEY_B64="${3:?Usage: Scripts/verify-appcast.sh <appcast.xml> <zip> <public-key-base64>}"

fail() {
  echo "verify-appcast: $1" >&2
  exit 1
}

[[ -f "$APPCAST" ]] || fail "appcast not found: $APPCAST"
[[ -f "$ZIP" ]] || fail "zip not found: $ZIP"

ENCLOSURE_COUNT="$(grep -c '<enclosure ' "$APPCAST" || true)"
if [[ "$ENCLOSURE_COUNT" -ne 1 ]]; then
  fail "expected exactly one <enclosure> in $APPCAST, found $ENCLOSURE_COUNT"
fi

ENCLOSURE_LINE="$(grep '<enclosure ' "$APPCAST")"

SIGNATURE="$(printf '%s' "$ENCLOSURE_LINE" | sed -nE 's/.*sparkle:edSignature="([^"]*)".*/\1/p')"
[[ -n "$SIGNATURE" ]] || fail "enclosure has no sparkle:edSignature attribute"

LENGTH="$(printf '%s' "$ENCLOSURE_LINE" | sed -nE 's/.*length="([^"]*)".*/\1/p')"
[[ -n "$LENGTH" ]] || fail "enclosure has no length attribute"

ACTUAL_LENGTH="$(stat -f%z "$ZIP")"
if [[ "$LENGTH" != "$ACTUAL_LENGTH" ]]; then
  fail "appcast length=$LENGTH does not match zip's actual size $ACTUAL_LENGTH bytes ($ZIP)"
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PUB_DER="$TMP_DIR/pub.der"
SIG_BIN="$TMP_DIR/sig.bin"

# Ed25519 SubjectPublicKeyInfo DER header (12 bytes) + 32 raw public key bytes.
{
  printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'
  printf '%s' "$PUBKEY_B64" | base64 -d 2>/dev/null || printf '%s' "$PUBKEY_B64" | base64 -D
} > "$PUB_DER"

printf '%s' "$SIGNATURE" | base64 -d > "$SIG_BIN" 2>/dev/null || printf '%s' "$SIGNATURE" | base64 -D > "$SIG_BIN"

if ! openssl pkeyutl -verify -pubin -inkey "$PUB_DER" -keyform DER -rawin -in "$ZIP" -sigfile "$SIG_BIN" \
    > "$TMP_DIR/verify.out" 2>&1; then
  if grep -qiE "unknown option|unsupported|rawin" "$TMP_DIR/verify.out"; then
    fail "the available openssl ($(openssl version)) cannot verify Ed25519 signatures with -rawin. Install a newer openssl (e.g. 'brew install openssl') and put it first on PATH."
  fi
  cat "$TMP_DIR/verify.out" >&2
  fail "Ed25519 signature verification failed for $ZIP against the given public key"
fi

echo "verify-appcast: OK — $APPCAST matches $ZIP (length=$ACTUAL_LENGTH, signature verified)."
