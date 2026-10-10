#!/bin/bash
# Sends push fixtures to a booted simulator with `xcrun simctl push`.
#   scripts/push-sim.sh <udid> <fixture.apns | fixture-dir | all> [bundle-id]
# `all` (or a directory) sends every *.apns in file order, 3 s apart (generates fresh fixtures for `all`).
# NOTE: whether the notification service extension is launched by simctl push depends on the runtime; the DEBUG push
# harness (`--push-harness`, see UITests/PushNSETests) reads the extension's own invocation marker to find out.
set -euo pipefail
cd "$(dirname "$0")/.."
udid="${1:?usage: push-sim.sh <udid> <fixture.apns|dir|all> [bundle-id]}"
what="${2:?usage: push-sim.sh <udid> <fixture.apns|dir|all> [bundle-id]}"
bundle="${3:-io.severin.orch}"
if [ "$what" = all ]; then
  what="${TMPDIR:-/tmp}/orch-push-fixtures"
  scripts/make-push-fixture.sh --out "$what" >/dev/null
fi
if [ -d "$what" ]; then files=("$what"/*.apns); else files=("$what"); fi
for f in "${files[@]}"; do
  echo "push $(basename "$f")"
  xcrun simctl push "$udid" "$bundle" "$f"
  [ ${#files[@]} -gt 1 ] && sleep 3
done
