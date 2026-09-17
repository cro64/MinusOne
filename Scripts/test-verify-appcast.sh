#!/usr/bin/env bash
set -euo pipefail

# Hermetic test for Scripts/verify-appcast.sh. Needs no Keychain, no network, and no build/
# artifacts: it generates its own throwaway Ed25519 key, signs a dummy file, and asserts
# verify-appcast.sh accepts the good case and rejects three tampered ones.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="$ROOT_DIR/Scripts/verify-appcast.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0

report() {
  local name="$1"
  local expected="$2" # "pass" or "fail"
  local actual_status="$3"
  if [[ "$expected" == "pass" && "$actual_status" -eq 0 ]]; then
    echo "PASS: $name"
  elif [[ "$expected" == "fail" && "$actual_status" -ne 0 ]]; then
    echo "PASS: $name"
  else
    echo "FAIL: $name (expected $expected, verify-appcast.sh exited $actual_status)"
    FAILURES=$((FAILURES + 1))
  fi
}

make_appcast() {
  local appcast_path="$1"
  local sig_b64="$2"
  local length="$3"
  cat > "$appcast_path" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item>
      <enclosure url="https://example.invalid/x.zip" sparkle:edSignature="$sig_b64" length="$length" type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF
}

# --- Set up a throwaway keypair and a dummy "zip". ---
KEY_PRIV="$TMP_DIR/key.pem"
openssl genpkey -algorithm ed25519 -out "$KEY_PRIV" 2>/dev/null

# Raw 32-byte public key, base64: last 32 bytes of the DER public key.
PUB_DER="$TMP_DIR/pub.der"
openssl pkey -in "$KEY_PRIV" -pubout -outform DER -out "$PUB_DER" 2>/dev/null
PUB_B64="$(tail -c 32 "$PUB_DER" | base64 | tr -d '\n')"

DUMMY_ZIP="$TMP_DIR/dummy.zip"
head -c 4096 /dev/urandom > "$DUMMY_ZIP"

SIG_BIN="$TMP_DIR/dummy.sig"
openssl pkeyutl -sign -rawin -inkey "$KEY_PRIV" -in "$DUMMY_ZIP" -out "$SIG_BIN" 2>/dev/null
SIG_B64="$(base64 < "$SIG_BIN" | tr -d '\n')"
LENGTH="$(stat -f%z "$DUMMY_ZIP")"

# --- Case 1: valid file → exit 0. ---
APPCAST_OK="$TMP_DIR/appcast-ok.xml"
make_appcast "$APPCAST_OK" "$SIG_B64" "$LENGTH"
status=0
"$VERIFY" "$APPCAST_OK" "$DUMMY_ZIP" "$PUB_B64" > "$TMP_DIR/out1.log" 2>&1 || status=$?
report "valid appcast/zip/key verifies" "pass" "$status"

# --- Case 2: one byte flipped in the file (same length) → exit non-zero. ---
TAMPERED_ZIP="$TMP_DIR/tampered.zip"
cp "$DUMMY_ZIP" "$TAMPERED_ZIP"
python3 - "$TAMPERED_ZIP" <<'PY'
import sys
path = sys.argv[1]
with open(path, "r+b") as f:
    f.seek(0)
    b = f.read(1)
    f.seek(0)
    f.write(bytes([b[0] ^ 0xFF]))
PY
status=0
"$VERIFY" "$APPCAST_OK" "$TAMPERED_ZIP" "$PUB_B64" > "$TMP_DIR/out2.log" 2>&1 || status=$?
report "one flipped byte (same length) is rejected" "fail" "$status"

# --- Case 3: length attribute off by one → exit non-zero. ---
APPCAST_BADLEN="$TMP_DIR/appcast-badlen.xml"
make_appcast "$APPCAST_BADLEN" "$SIG_B64" "$((LENGTH + 1))"
status=0
"$VERIFY" "$APPCAST_BADLEN" "$DUMMY_ZIP" "$PUB_B64" > "$TMP_DIR/out3.log" 2>&1 || status=$?
report "length off by one is rejected" "fail" "$status"

# --- Case 4: a different key's public half → exit non-zero. ---
OTHER_KEY_PRIV="$TMP_DIR/other-key.pem"
openssl genpkey -algorithm ed25519 -out "$OTHER_KEY_PRIV" 2>/dev/null
OTHER_PUB_DER="$TMP_DIR/other-pub.der"
openssl pkey -in "$OTHER_KEY_PRIV" -pubout -outform DER -out "$OTHER_PUB_DER" 2>/dev/null
OTHER_PUB_B64="$(tail -c 32 "$OTHER_PUB_DER" | base64 | tr -d '\n')"
status=0
"$VERIFY" "$APPCAST_OK" "$DUMMY_ZIP" "$OTHER_PUB_B64" > "$TMP_DIR/out4.log" 2>&1 || status=$?
report "wrong public key is rejected" "fail" "$status"

echo
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All cases passed."
  exit 0
else
  echo "$FAILURES case(s) failed."
  exit 1
fi
