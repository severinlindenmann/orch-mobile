#!/bin/bash
# Host driver for UITests/HubPushNSETests: creates fresh fixtures, runs the UI test on <udid>, and plays the APNs sender
# with `xcrun simctl push` when the test says it is ready (a simulator process cannot call simctl itself).
#   scripts/hub-push-nse-test.sh <udid>
# Result: the test passes when the notification service extension wrote its marker and applied every rule; it is
# SKIPPED with "UNVERIFIED: ..." when simctl push did not launch the extension (read the xcodebuild output for it).
set -uo pipefail
cd "$(dirname "$0")/.."
udid="${1:?usage: hub-push-nse-test.sh <udid>}"
dir="$(mktemp -d "${TMPDIR:-/tmp}/orch-push-nse.XXXXXX")"
scripts/make-push-fixture.sh --out "$dir" >/dev/null || exit 1
xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
fixtures=("$dir"/*.apns)
TEST_RUNNER_ORCH_PUSH_DIR="$dir" xcodebuild -project Orch.xcodeproj -scheme Orch -destination "platform=iOS Simulator,id=$udid" \
  -derivedDataPath .build/dd CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES -only-testing:OrchUITests/HubPushNSETests test \
  >"$dir/xcodebuild.log" 2>&1 &
xb=$!
for i in $(seq 1 ${#fixtures[@]}); do
  until [ -e "$dir/ready-$i" ]; do
    kill -0 "$xb" 2>/dev/null || break 2
    sleep 0.5
  done
  echo "push ${fixtures[$((i-1))]##*/}"
  xcrun simctl push "$udid" io.severin.orch "${fixtures[$((i-1))]}" || echo "simctl push failed"
  touch "$dir/sent-$i"
  until [ -e "$dir/checked-$i" ]; do
    kill -0 "$xb" 2>/dev/null || break 2
    sleep 0.5
  done
done
wait "$xb"; status=$?
grep -E "error:|UNVERIFIED|Executed|TEST (SUCCEEDED|FAILED)" "$dir/xcodebuild.log" | cut -c1-1200
echo "fixtures and log: $dir"
exit "$status"
