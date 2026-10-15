#!/bin/bash
# The test hooks (RealmContext.liveLoopbackForTesting, NWRequestSender(loopbackOrigin:): `package` + `#if DEBUG`; LiveTransport.testingTransport: public but `#if DEBUG`)
# and must never be referenced from a shipped target. Fails if App/, NotificationService/ or ShareExtension/ mention them.
set -euo pipefail
cd "$(dirname "$0")/.."
dirs=()
for d in App NotificationService ShareExtension; do [ -d "$d" ] && dirs+=("$d"); done
[ ${#dirs[@]} -gt 0 ] || { echo "error: no shipped target directories found" >&2; exit 2; }
set +e
hits=$(grep -rnE "liveLoopbackForTesting|loopbackOrigin|isLoopbackHTTP|testingTransport" "${dirs[@]}")
rc=$?
set -e
# grep: 0 = matches (bad), 1 = no match (clean), anything else = grep itself failed (never treated as clean)
if [ $rc -eq 0 ]; then echo "$hits"; echo "error: test-only loopback hook referenced from a shipped target" >&2; exit 1; fi
if [ $rc -ne 1 ]; then echo "error: grep failed (exit $rc)" >&2; exit 2; fi
echo "no test hooks in shipped targets"
