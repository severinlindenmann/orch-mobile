#!/bin/bash
# The Simulator dev-sandbox lane (host 11A.17, C2b increment 5) must exist only where it is meant to:
#   - Orch, Debug, device       : no `DevSandbox` symbol, no banner string (the lane is compiled only under DEBUG && targetEnvironment(simulator))
#   - Orch, Release, device     : the same
#   - Orch, Release, Simulator  : the same
#   - Orch, Debug, Simulator    : OrchKit's lane code is there (its `DevSandboxLane` sentinel) but the App side is not: no enabler is ever minted,
#                                 no banner (`DevSandboxBanner`, `DevSandboxText`, the banner string)
#   - OrchDevSandbox, Debug, Simulator: the lane, the App enabler and the banner
# Builds what is missing (unsigned, its own derived data) and inspects every Mach-O in the .app with nm and strings.
# Usage: SIMULATOR_ID=<udid> scripts/check-dev-sandbox-symbols.sh   (or ORCH_TEST_DESTINATION="platform=iOS Simulator,name=iPhone 16")
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -n "${SIMULATOR_ID:-}" ]; then SIM="platform=iOS Simulator,id=$SIMULATOR_ID"; else SIM="${ORCH_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 16}"; fi
[ -d Orch.xcodeproj ] || xcodegen generate >/dev/null
fail=0

build() { # scheme config destination derived-data
  local log; log="$(mktemp -t orch-lane-build)"
  xcodebuild -project Orch.xcodeproj -scheme "$1" -configuration "$2" -destination "$3" -derivedDataPath "$4" CODE_SIGNING_ALLOWED=NO build >"$log" 2>&1 \
    || { tail -30 "$log"; echo "error: build failed: $1 $2 $3" >&2; exit 1; }
}

machos() { # app bundle -> every Mach-O file inside
  find "$1" -type f | while read -r f; do file "$f" | grep -q "Mach-O" && echo "$f"; done
}

count() { # app pattern -> number of matching symbols and strings
  local n=0 c
  while read -r f; do
    c=$( { nm -a "$f" 2>/dev/null; strings -a "$f" 2>/dev/null; } | grep -Ec "$2" || true )
    n=$((n + c))
  done < <(machos "$1")
  echo "$n"
}

expect_absent() { # label app pattern
  local n; n=$(count "$2" "$3")
  if [ "$n" -ne 0 ]; then echo "error: $1: $n lane symbols/strings matching '$3' (expected none)" >&2; fail=1; else echo "ok: $1: none of '$3'"; fi
}
expect_present() {
  local n; n=$(count "$2" "$3")
  if [ "$n" -eq 0 ]; then echo "error: $1: no '$3' found (expected the lane)" >&2; fail=1; else echo "ok: $1: '$3' present ($n)"; fi
}

app() { echo "$1/Build/Products/$2/$3.app"; }

build Orch Debug generic/platform=iOS .build/dd-device-debug
build Orch Release generic/platform=iOS .build/dd-device-release
build Orch Release "$SIM" .build/dd-release-sym
build Orch Debug "$SIM" .build/dd-debug-sym
build OrchDevSandbox Debug "$SIM" .build/dd-variant

ANY='DevSandbox|DEV SANDBOX|convenience signing'
expect_absent "Orch Debug device"      "$(app .build/dd-device-debug Debug-iphoneos Orch)"        "$ANY"
expect_absent "Orch Release device"    "$(app .build/dd-device-release Release-iphoneos Orch)"    "$ANY"
expect_absent "Orch Release Simulator" "$(app .build/dd-release-sym Release-iphonesimulator Orch)" "$ANY"
expect_absent "Orch Debug Simulator (App side)" "$(app .build/dd-debug-sym Debug-iphonesimulator Orch)" 'DevSandboxBanner|DevSandboxText|DEV SANDBOX'
expect_present "Orch Debug Simulator (OrchKit sentinel)" "$(app .build/dd-debug-sym Debug-iphonesimulator Orch)" 'DevSandboxLane'
V="$(app .build/dd-variant Debug-iphonesimulator OrchDevSandbox)"
expect_present "OrchDevSandbox (sentinel)" "$V" 'DevSandboxLane'
expect_present "OrchDevSandbox (banner)"   "$V" 'DevSandboxBanner'
exit $fail
