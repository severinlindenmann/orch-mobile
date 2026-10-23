#!/usr/bin/env bash
# hub-s6: the Simulator lane of the hub scenario S6 (V3 B7, orch-core #867). The real app (Debug, scheme OrchHubE2E) pairs with a real
# local hub from the 6.4 link, lists the workspaces the hub grants and, when asked, signs a question answer with the Simulator's Face ID.
# Run by the orch-dev-kit scenario hub-S6 (e2e/lib/hub_s6_flow.py), which owns the hub, the relay and the host and verifies the result on
# the hub side. Standalone it needs the same environment (see HubE2ETests/E2EHubS6Tests.swift for the ORCH_E2E_HUB_* names).
#
# Steps (each prints PASS: / FAIL:):  build, boot, faceid, sim-pair, sim-list, sim-sign-tap, xcodebuild
#   build         xcodegen + xcodebuild build-for-testing of scheme OrchHubE2E (before anything is booted)
#   boot          the Simulator named ORCH_E2E_SIM_NAME (default orch-e2e-hub; created when missing) is booted, nothing else
#   faceid        Face ID enrolled (before pairing: the app records the enrolled-face state at pairing)
#   sim-pair      the UI test paired the app with the hub (fingerprint equals the admin's, password + code, "Paired")
#   sim-list      the home listed exactly the granted workspaces (a "LIST: <prefixes>" line follows)
#   sim-sign-tap  (ORCH_E2E_HUB_SIGN=1) the review was confirmed with a matching Face ID and the hub signed
#   xcodebuild    the UI test exited 0
# The caller holds the `simulator` lease (the kit's hub_s6_flow.py takes it); this script boots and shuts the Simulator down itself.
# Environment: ORCH_MOBILE_DIR (this checkout), ORCH_E2E_SIM_NAME / ORCH_E2E_SIM_UDID, ORCH_E2E_DIR (work dir, default $HOME/e2e/hub-s6-sim),
#   ORCH_E2E_HUB_LINK, _FINGERPRINT, _PASSWORD, _TOTP_SECRET, _TOTP_LAST, _WS, _NOT_WS, _QUESTION, _OPTION, _SIGN (see the UI test).
# Only processes this script started are signalled. Secrets are passed in the test's environment only, never printed.

hs6_sim_udid() { # <name>: the UDID of the available Simulator with exactly this name, else create it (iPhone Pro, newest iOS runtime)
  python3 - "$1" <<'PY'
import json, subprocess, sys
name = sys.argv[1]
d = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))["devices"]
for runtime, devices in d.items():
    for x in devices:
        if x["name"] == name and x["isAvailable"]:
            print(x["udid"]); raise SystemExit(0)
rts = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "available", "-j"]))["runtimes"]
ios = sorted((r for r in rts if r["platform"] == "iOS"), key=lambda r: [int(p) for p in r["version"].split(".")])
if not ios:
    raise SystemExit(1)
types = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devicetypes", "-j"]))["devicetypes"]
phones = [t for t in types if t["name"].startswith("iPhone") and "Pro" in t["name"] and "Max" not in t["name"]] or [t for t in types if t["name"].startswith("iPhone")]
print(subprocess.check_output(["xcrun", "simctl", "create", name, phones[-1]["identifier"], ios[-1]["identifier"]], text=True).strip())
PY
}

hs6_has() { # <file> <prefix>: whether a line of the file starts with the prefix (the UI test prints each event as "ORCH_E2E_HUB <event>" too)
  grep -aqE "^(ORCH_E2E_HUB )?$2" "$1" 2>/dev/null
}

hs6_event() { # <file> <prefix>: the rest of the first line that starts with the prefix
  grep -aE "^(ORCH_E2E_HUB )?$2" "$1" 2>/dev/null | head -n 1 | sed -E "s/^(ORCH_E2E_HUB )?$2 ?//"
}

run_scenario() {
  local mobile="${ORCH_MOBILE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local name="${ORCH_E2E_SIM_NAME:-orch-e2e-hub}" udid="${ORCH_E2E_SIM_UDID:-}"
  work="${ORCH_E2E_DIR:-$HOME/e2e/hub-s6-sim}"
  xb_pid="" face_pid="" booted_udid=""
  local failed=0 sign="${ORCH_E2E_HUB_SIGN:-0}"
  local dd="$mobile/.build/dd-e2e-hub"

  step_pass() { echo "PASS: $1"; }
  step_fail() { echo "FAIL: $1" >&2; failed=1; }

  # shellcheck disable=SC2329 # EXIT trap
  cleanup() {
    local p
    for p in "$face_pid" "$xb_pid"; do
      [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && kill "$p" 2>/dev/null
    done
    [[ -n "$booted_udid" ]] && xcrun simctl shutdown "$booted_udid" >/dev/null 2>&1
    return 0
  }
  trap cleanup EXIT

  # -- preconditions
  [[ -f "$mobile/project.yml" ]] || { echo "FAIL: ORCH_MOBILE_DIR=$mobile is not an orch-mobile checkout" >&2; return 1; }
  if ! command -v xcodegen >/dev/null || ! command -v xcodebuild >/dev/null; then echo "FAIL: xcodegen and xcodebuild are needed" >&2; return 1; fi
  local v full
  for v in LINK FINGERPRINT PASSWORD TOTP_SECRET WS; do
    full="ORCH_E2E_HUB_$v"
    [[ -n "${!full:-}" ]] || { echo "FAIL: $full is not set" >&2; return 1; }
  done
  [[ -n "$udid" ]] || udid=$(hs6_sim_udid "$name") || { echo "FAIL: no Simulator named $name and none could be created" >&2; return 1; }
  (umask 077 && mkdir -p "$work") || return 1
  : >"$work/events"

  # -- build (nothing is booted yet)
  local xbase=(xcodebuild -project "$mobile/Orch.xcodeproj" -scheme OrchHubE2E -destination "id=$udid" -derivedDataPath "$dd"
    -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1)
  if (cd "$mobile" && xcodegen generate >"$work/xcodegen.log" 2>&1 && "${xbase[@]}" build-for-testing >"$work/build.log" 2>&1); then
    step_pass "build (OrchHubE2E, build-for-testing)"
  else
    step_fail "build (see $work/build.log)"
    return 1
  fi

  # -- boot: one Simulator only
  if ! xcrun simctl list devices booted | grep -q "$udid" && xcrun simctl list devices booted | grep -q Booted; then
    step_fail "boot (another Simulator is booted; this lane never runs two. Shut it down first)"
    return 1
  fi
  if ! xcrun simctl list devices booted | grep -q "$udid"; then
    xcrun simctl boot "$udid" >"$work/boot.log" 2>&1 || { step_fail "boot (see $work/boot.log)"; return 1; }
    booted_udid="$udid" # booted here, so shut down here
  fi
  xcrun simctl bootstatus "$udid" -b >>"$work/boot.log" 2>&1 || true
  step_pass "boot ($name)"

  # -- Face ID: enrolled before the app pairs (the app records the enrolled-face state then). Matches follow while the UI test waits for one.
  if xcrun simctl spawn "$udid" notifyutil -s com.apple.BiometricKit.enrollmentChanged 1 >>"$work/faceid.log" 2>&1 &&
    xcrun simctl spawn "$udid" notifyutil -p com.apple.BiometricKit.enrollmentChanged >>"$work/faceid.log" 2>&1; then
    step_pass "faceid (enrolled)"
  else
    step_fail "faceid (enrollment failed; see $work/faceid.log)"
    return 1
  fi

  # -- the phone: the UI test. Every value goes in its environment only.
  local envs=("TEST_RUNNER_ORCH_E2E_DIR=$work" "TEST_RUNNER_ORCH_E2E_HUB_SIGN=$sign")
  for v in LINK FINGERPRINT PASSWORD TOTP_SECRET TOTP_LAST WS NOT_WS QUESTION OPTION; do
    full="ORCH_E2E_HUB_$v"
    envs+=("TEST_RUNNER_$full=${!full:-}")
  done
  env "${envs[@]}" "${xbase[@]}" test-without-building -only-testing:OrchHubE2ETests/E2EHubS6Tests/testPairListSign \
    </dev/null >"$work/xcodebuild.log" 2>&1 &
  xb_pid=$!
  envs=()

  # Face ID matches: from "faceid wanted" until "signed" (the prompt may need a moment; a match with no prompt open is harmless).
  (
    until hs6_has "$work/events" "faceid wanted" || hs6_has "$work/xcodebuild.log" "faceid wanted"; do
      kill -0 "$xb_pid" 2>/dev/null || exit 0
      sleep 0.5
    done
    for ((n = 0; n < 40; n++)); do
      xcrun simctl spawn "$udid" notifyutil -p com.apple.BiometricKit_Sim.pearl.match >>"$work/faceid.log" 2>&1
      hs6_has "$work/events" "signed" && exit 0
      kill -0 "$xb_pid" 2>/dev/null || exit 0
      sleep 1.5
    done
  ) &
  face_pid=$!

  local deadline=$((SECONDS + ${ORCH_E2E_HUB_TIMEOUT:-600})) rc=0
  while kill -0 "$xb_pid" 2>/dev/null; do
    if ((SECONDS > deadline)); then echo "FAIL: the UI test did not finish in time" >&2; break; fi
    # xcodebuild can linger after the test (result bundle, simulator teardown): its own verdict in the log ends the wait after a moment
    if grep -aqE "Executed 1 test, with [0-9]+ failures?" "$work/xcodebuild.log" 2>/dev/null; then sleep 5; break; fi
    sleep 1
  done
  if kill -0 "$xb_pid" 2>/dev/null; then
    kill "$xb_pid" 2>/dev/null
    wait "$xb_pid" 2>/dev/null
    grep -aqE "Executed 1 test, with 0 failures" "$work/xcodebuild.log" 2>/dev/null && rc=0 || rc=99
  else
    wait "$xb_pid" 2>/dev/null
    rc=$?
  fi
  xb_pid=""

  # -- results, from the events the test wrote (the file, else its printed copies in the log)
  local lines="$work/events" ev
  [[ -s "$lines" ]] || lines="$work/xcodebuild.log"
  if hs6_has "$lines" "pair ok"; then step_pass "sim-pair (fingerprint matched, password + code, paired)"; else step_fail "sim-pair (see $work/xcodebuild.log)"; fi
  if ev=$(hs6_event "$lines" "list") && [[ -n "$ev" ]]; then
    echo "LIST: $ev"
    step_pass "sim-list (the home shows $ev)"
  else
    step_fail "sim-list (the home listed nothing; see $work/xcodebuild.log)"
  fi
  if [[ "$sign" == 1 ]]; then
    if hs6_has "$lines" "signed"; then step_pass "sim-sign-tap (Face ID matched, the hub signed)"; else step_fail "sim-sign-tap (see $work/xcodebuild.log)"; fi
  fi
  if ((rc == 0)); then step_pass "xcodebuild (UI test passed)"; else step_fail "xcodebuild (exit $rc; see $work/xcodebuild.log)"; grep -a "error:" "$work/xcodebuild.log" | tail -n 5 >&2; fi

  if ((failed == 0)); then echo "hub-s6: PASS"; else echo "hub-s6: FAIL" >&2; fi
  return "$failed"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -uo pipefail
  run_scenario
fi
