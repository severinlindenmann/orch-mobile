#!/bin/bash
# Runs the LaunchOptions unit tests under the Release configuration: debug flags (--demo, --demo-seed, --ui-preview, ...) must be ignored.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="${ORCH_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 16}"
xcodegen generate >/dev/null
xcodebuild -project Orch.xcodeproj -scheme Orch -configuration Release -destination "$DEST" -derivedDataPath .build/dd-release \
  ENABLE_TESTABILITY=YES CODE_SIGNING_ALLOWED=NO \
  -only-testing:OrchTests/MappingTests/testDefaultInitIgnoresDebugFlagsInRelease \
  -only-testing:OrchTests/LaunchOptionsTests test 2>&1 | tee /tmp/orch-release-flags.log | tail -5
grep -q "TEST SUCCEEDED" /tmp/orch-release-flags.log
echo "release flag check OK"
