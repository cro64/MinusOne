#!/usr/bin/env bash
set -euo pipefail

# Runs the XCUITest suite in Tests/MinusOneUITests.
#
# Deliberately NOT `swift test`: SwiftPM can only produce a unit-test bundle, and `XCUIApplication`
# refuses to run in one ("Device is not configured for UI testing — use of XCUIApplication is not
# supported"), so every test fails in `setUp` before touching the app. The UI-testing bundle comes
# from a throwaway xcodegen project instead (`project.yml` is the source of truth; the generated
# .xcodeproj is gitignored) — the procedure HANDOFF.md documents.
#
# Needs, once per machine: your terminal enabled under System Settings → Privacy & Security →
# Accessibility (to drive the UI) and → Developer Tools (so xcodebuild can sign the entitled test
# bundle; without it the failure is a misleading `ld: open() failed, errno=1` linker error).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found — install it with: brew install xcodegen" >&2
  exit 1
fi

cd "$ROOT_DIR"
xcodegen generate
"$ROOT_DIR/Scripts/build-app.sh" debug
xcodebuild test \
  -project MinusOneUITests.xcodeproj \
  -scheme MinusOneUITests \
  -destination 'platform=macOS,arch=arm64' \
  "$@"
