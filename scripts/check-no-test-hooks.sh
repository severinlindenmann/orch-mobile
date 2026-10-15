#!/bin/bash
# The test hooks (RealmContext.liveLoopbackForTesting, NWRequestSender(loopbackOrigin:): `package` + `#if DEBUG`; LiveTransport.testingTransport: public but `#if DEBUG`)
# and must never be referenced from a shipped target. Fails if App/, NotificationService/ or ShareExtension/ mention them.
set -euo pipefail
cd "$(dirname "$0")/.."
dirs=()
for d in App NotificationService ShareExtension; do [ -d "$d" ] && dirs+=("$d"); done
[ ${#dirs[@]} -gt 0 ] || { echo "error: no shipped target directories found" >&2; exit 2; }
# The one allowed exception: the DEBUG UI-test storage, which must be compiled into the DEBUG app (UI tests drive the app process). It may
# only name `unreachableForUITests`, and only as a file whose entire body is one `#if DEBUG ... #endif` (no #else, no nesting), so a
# Release compile contains none of it.
allowed="App/Live/LiveUITestSupport.swift"
if [ -f "$allowed" ]; then
  first=$(grep -v '^[[:space:]]*$' "$allowed" | head -1)
  last=$(grep -v '^[[:space:]]*$' "$allowed" | tail -1)
  directives=$(grep -cE '^[[:space:]]*#(if|else|elseif|endif)' "$allowed" || true)
  if [ "$first" != "#if DEBUG" ] || [ "$last" != "#endif" ] || [ "$directives" != "2" ]; then
    echo "error: $allowed must be wrapped entirely in a single '#if DEBUG ... #endif'" >&2; exit 1
  fi
fi
# Every file of the shipped targets except the one allowed path (matched by its exact path, not by its basename).
files=()
while IFS= read -r f; do files+=("$f"); done < <(find "${dirs[@]}" -type f ! -path "$allowed")
[ ${#files[@]} -gt 0 ] || { echo "error: no files found" >&2; exit 2; }
set +e
hits=$(grep -nE "liveLoopbackForTesting|loopbackOrigin|isLoopbackHTTP|testingTransport|unreachableForUITests" "${files[@]}")
rc=$?
set -e
# grep: 0 = matches (bad), 1 = no match (clean), anything else = grep itself failed (never treated as clean)
if [ $rc -eq 0 ]; then echo "$hits"; echo "error: test-only loopback hook referenced from a shipped target" >&2; exit 1; fi
if [ $rc -ne 1 ]; then echo "error: grep failed (exit $rc)" >&2; exit 2; fi
echo "no test hooks in shipped targets"
