#!/bin/bash
# Usage: scripts/assert-test-count.sh <xcodebuild log> <minimum executed tests> <label>
# Fails unless the log says TEST SUCCEEDED and at least <minimum> tests ran, so a filter that matches nothing cannot pass vacuously.
# Reads both runners: Swift Testing ("Test run with N tests") and XCTest (the last "Executed N tests" line, the overall total).
set -euo pipefail
LOG="$1"; MIN="$2"; LABEL="${3:-tests}"
ST=$(grep -Eo "Test run with [0-9]+ tests?" "$LOG" | tail -1 | grep -Eo "[0-9]+" || true)
XC=$(grep -Eo "Executed [0-9]+ tests?" "$LOG" | tail -1 | grep -Eo "[0-9]+" || true)
N=$(( ${ST:-0} > ${XC:-0} ? ${ST:-0} : ${XC:-0} ))
if ! grep -q "TEST SUCCEEDED" "$LOG" || [ "$N" -lt "$MIN" ]; then
  echo "error: $LABEL did not run enough tests (executed: $N, expected at least $MIN)" >&2; exit 1
fi
echo "$LABEL OK ($N tests, at least $MIN expected)"
