#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aibar-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
SWIFTC=(swiftc)
if [ -n "${AI_BAR_SWIFT_SDK:-}" ]; then
    SWIFTC+=(-sdk "$AI_BAR_SWIFT_SDK")
fi
cd "$ROOT_DIR"
"${SWIFTC[@]}" \
    Sources/AIBar/Models.swift Sources/AIBar/DisplayPreferences.swift \
    Sources/AIBar/CodexLiveUsage.swift Sources/AIBar/CodexQuotaClient.swift \
    Tests/AIBarTests/main.swift -o "$TEST_DIR/codex-quota-tests"
"$TEST_DIR/codex-quota-tests"
