#!/usr/bin/env bash
# Runs the unit and integration tests on macOS.
#   scripts/test.sh                      # all automated tests
#   MSA_CAMERA_TESTS=1 scripts/test.sh   # + real camera tests (prompts for permission)
#   MSA_KEYCHAIN_TESTS=1 scripts/test.sh # + real Keychain round trip
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift test --package-path "$ROOT/MacSecurityAgent" "$@"
