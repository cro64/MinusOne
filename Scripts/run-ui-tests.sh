#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT_DIR/Scripts/build-app.sh" debug

swift test --package-path "$ROOT_DIR" --filter MinusOneUITests
