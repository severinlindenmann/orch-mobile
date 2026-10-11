#!/bin/bash
# Runs the LaunchOptions unit tests under the Release configuration: debug flags (--demo, --demo-seed, --ui-preview, ...) must be ignored.
# Uses its own derived data (the hosted steps are ad-hoc signed; this one is unsigned and needs no entitlements).
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -n "${SIMULATOR_ID:-}" ]; then DEST="platform=iOS Simulator,id=$SIMULATOR_ID"; else DEST="${ORCH_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 16}"; fi
[ -d Orch.xcodeproj ] || xcodegen generate >/dev/null
LOG="$(mktemp -t orch-release-flags)"
xcodebuild -project Orch.xcodeproj -scheme Orch -configuration Release -destination "$DEST" -derivedDataPath .build/dd-release-test \
  ENABLE_TESTABILITY=YES CODE_SIGNING_ALLOWED=NO \
  -only-testing:OrchTests/MappingTests/testDefaultInitIgnoresDebugFlagsInRelease \
  -only-testing:OrchTests/LaunchOptionsTests test >"$LOG" 2>&1 || { tail -30 "$LOG"; exit 1; }
tail -5 "$LOG"
N=$(grep -Eo "Executed [0-9]+ tests?" "$LOG" | tail -1 | grep -Eo "[0-9]+" || echo 0)
if ! grep -q "TEST SUCCEEDED" "$LOG" || [ "$N" -lt 2 ]; then echo "error: release flag check did not run its tests (executed: $N)" >&2; exit 1; fi
echo "release flag check OK ($N tests)"
