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
# The in-process fake hub and the launch-argument hooks (--hub-fake, --hub-pair, --hub-sign, --push-harness) belong to DEBUG only: outside a
# `#if DEBUG` branch no line of App/ may name them (LaunchOptions.swift is exempt: it ignores every flag in Release at run time, which
# scripts/check-release-flags.sh proves). Tracks nested `#if`/`#else`/`#endif`; `#if DEBUG` (exactly) opens a DEBUG branch.
bad=$(awk '
  FNR==1 { n=0 }
  /^[[:space:]]*#if[[:space:]]/ { n++; dbg[n] = ($0 ~ /^[[:space:]]*#if[[:space:]]+DEBUG[[:space:]]*$/) ? 1 : 0; next }
  /^[[:space:]]*#(else|elseif)/ { if (n>0) dbg[n]=0; next }
  /^[[:space:]]*#endif/ { if (n>0) n--; next }
  /^[[:space:]]*\/\// { next }
  { d=0; for (i=1;i<=n;i++) if (dbg[i]) d=1
    if (!d && $0 ~ /FakeHub|OrchFakeHost|ScriptedBiometry|"--hub-fake"|"--hub-pair"|"--hub-sign"|"--push-harness"/) print FILENAME ":" FNR ": " $0 }
' $(find App -name '*.swift' ! -path "$allowed" ! -path App/LaunchOptions.swift))
if [ -n "$bad" ]; then echo "$bad"; echo "error: fake-hub / launch-argument hook outside #if DEBUG in a shipped target" >&2; exit 1; fi
echo "no test hooks in shipped targets"
