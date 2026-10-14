#!/bin/bash
# The loopback-http test hooks (RealmContext.liveLoopbackForTesting, URLSessionRequestSender(loopbackOrigin:)) are `package` + `#if DEBUG`
# and must never be referenced from a shipped target. Fails if App/, NotificationService/ or ShareExtension/ mention them.
set -euo pipefail
cd "$(dirname "$0")/.."
dirs=()
for d in App NotificationService ShareExtension; do [ -d "$d" ] && dirs+=("$d"); done
if [ ${#dirs[@]} -gt 0 ] && grep -rnE "liveLoopbackForTesting|loopbackOrigin|isLoopbackHTTP" "${dirs[@]}"; then
  echo "error: test-only loopback hook referenced from a shipped target" >&2; exit 1
fi
echo "no test hooks in shipped targets"
