#!/usr/bin/env bash
# sim-pair-answer: pair the iOS Simulator (OrchDevSandbox variant) with a sandbox host through relay.dev, answer a question on the
# phone, check the answer on the Mac. Standalone: ORCH_CORE_DIR=<orch-core checkout> scripts/e2e/sim-pair-answer.sh
# (also run by .github/workflows/e2e-nightly.yml, and by the orch-dev-kit wrapper e2e/run.sh sim-pair-answer). Sourcing it only defines the functions.
#
# Steps (each prints PASS:/FAIL:):  build, invite, up, link, phone, ask, answer, xcodebuild. PASS only if all pass.
#   build     xcodegen + xcodebuild build-for-testing of scheme OrchDevSandbox (before the invite: the offer lives 1 h)
#   invite    ssh with the restricted key (forced command: `orch-relay invite create --ttl 1h`) -> a 0600 file; never printed
#   up        dev-pair up --sim-convenience against relay.dev, in the background, codes through <root>/codes
#   link      <root>/pair.json appears (it holds the pair link; the link is only passed to xcodebuild in the environment)
#   phone     the UI test OrchDevSandboxUITests/E2EPairAnswerTests/testPairAndAnswer starts; the codes it prints
#             (ORCH_E2E_CODE <offer> <phase> <CODE>) are relayed into the FIFO when its own file write did not arrive
#   ask       dev-pair up exits 0 (approved), then dev-pair ask creates a ticket + a free-text question with the nonce
#   answer    dev-pair check-answer sees question.answered "e2e_ok_<nonce>" signed by the paired device
#   xcodebuild the UI test exits 0 (it saw the settlement)
# Environment (ORCH_CORE_DIR is required; the rest is optional):
#   ORCH_CORE_DIR             an orch-core checkout with plugins/orch-core/.venv (uv sync --locked)   E2E_BASE  $HOME/e2e (short, not under /tmp)
#   ORCH_E2E_INVITE_KEY_FILE  ~/.ssh/orch_invite_ed25519     ORCH_E2E_INVITE_HOST  orch-invite@179.237.125.155 (a bare host gets the orch-invite@ user)
#   ORCH_E2E_KNOWN_HOSTS      a known_hosts file to pin the VPS host key (CI); default: ssh's own
#   ORCH_MOBILE_DIR           this checkout         ORCH_E2E_SIM_UDID     the booted iPhone simulator, else the first available iOS iPhone
#   ORCH_E2E_RELAY            https://relay.dev.severin.io   ORCH_E2E_ASK_TIMEOUT  240 (seconds for check-answer)
# Only processes this script started are signalled; the sandbox is stopped by `dev-pair down` (recorded PIDs only).

SPA_ROOT_MAX=52 # dev-pair: <root>/run/<32 hex>/host.sock must fit a 100-byte unix socket path

spa_root_ok() { # <path>: short enough for the host's control socket
  ((${#1} <= SPA_ROOT_MAX))
}

spa_code_line() { # <line>: print "<offer> <phase> <CODE>" for a stdout fallback line "ORCH_E2E_CODE <offer> <phase> <CODE>", else fail
  local tag offer phase code extra
  read -r tag offer phase code extra <<<"$1" || true
  [[ "$tag" == ORCH_E2E_CODE && -z "$extra" ]] || return 1
  [[ "$offer" =~ ^[0-9a-f]{32}$ && "$phase" =~ ^(sas|cert_code)$ && "$code" =~ ^[A-Za-z0-9]{6}$ ]] || return 1
  printf '%s %s %s\n' "$offer" "$phase" "$code"
}

spa_pick_sim() { # the booted iPhone simulator if any, else the first available iPhone on an iOS runtime
  python3 - <<'PY'
import json, subprocess
d = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))["devices"]
c = [x for r, v in sorted(d.items()) if "iOS" in r for x in v if x["isAvailable"] and x["name"].startswith("iPhone")]
c.sort(key=lambda x: x["state"] != "Booted")
if not c:
    raise SystemExit(1)
print(c[0]["udid"])
PY
}

spa_nonce() { od -An -N4 -tx1 /dev/urandom | tr -d ' \n'; }

spa_fifo_write() { # <fifo> <line>: a non-blocking write (fails at once when nobody reads)
  python3 - "$1" "$2" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_NONBLOCK)
os.write(fd, (sys.argv[2] + "\n").encode())
os.close(fd)
PY
}

run_scenario() {
  # Globals (not local): the EXIT trap runs after run_scenario has returned, when its locals are gone.
  : "${ORCH_CORE_DIR:?ORCH_CORE_DIR is required (an orch-core checkout)}"
  E2E_BASE="${E2E_BASE:-$HOME/e2e}"
  core="$ORCH_CORE_DIR/plugins/orch-core"
  py="$core/.venv/bin/python"
  local mobile="${ORCH_MOBILE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local udid="${ORCH_E2E_SIM_UDID:-}"
  local key="${ORCH_E2E_INVITE_KEY_FILE:-$HOME/.ssh/orch_invite_ed25519}"
  local host="${ORCH_E2E_INVITE_HOST:-orch-invite@179.237.125.155}"
  [[ "$host" == *@* ]] || host="orch-invite@$host"
  local relay="${ORCH_E2E_RELAY:-https://relay.dev.severin.io}"
  local ask_timeout="${ORCH_E2E_ASK_TIMEOUT:-240}"
  work="$E2E_BASE/spa"      # logs and the invite; recreated each run
  root="$E2E_BASE/spa-sbx"  # the sandbox root (dev-pair creates it exclusively)
  invite="$work/invite"
  up_pid="" xb_pid="" relay_pid=""
  local dd="$mobile/.build/dd-e2e" nonce out rc=0 failed=0

  step_pass() { echo "PASS: $1"; }
  step_fail() { echo "FAIL: $1" >&2; failed=1; }
  dp() { (cd "$core" && "$py" scripts/dev-pair "$@"); }

  # shellcheck disable=SC2329 # EXIT trap
  cleanup() {
    local p
    for p in "$relay_pid" "$xb_pid"; do
      [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && kill "$p" 2>/dev/null
    done
    if [[ -n "$up_pid" ]] && kill -0 "$up_pid" 2>/dev/null; then kill "$up_pid" 2>/dev/null; sleep 2; fi
    if [[ -e "$root/.orch-dev-sandbox" ]]; then dp down --root "$root" >>"$work/down.log" 2>&1 || echo "WARN: dev-pair down failed (see $work/down.log)" >&2; fi
    rm -f "$invite"
  }
  trap cleanup EXIT

  # -- preconditions
  [[ -x "$py" ]] || { echo "FAIL: $py missing (cd $core && uv sync --locked)" >&2; return 1; }
  [[ -f "$mobile/project.yml" ]] || { echo "FAIL: ORCH_MOBILE_DIR=$mobile is not an orch-mobile checkout" >&2; return 1; }
  [[ -r "$key" ]] || { echo "FAIL: invite key $key not readable (ORCH_E2E_INVITE_KEY_FILE)" >&2; return 1; }
  spa_root_ok "$root" || { echo "FAIL: sandbox root $root is longer than $SPA_ROOT_MAX bytes (set E2E_BASE shorter)" >&2; return 1; }
  if ! command -v xcodegen >/dev/null || ! command -v xcodebuild >/dev/null; then echo "FAIL: xcodegen and xcodebuild are needed" >&2; return 1; fi
  [[ -n "$udid" ]] || udid=$(spa_pick_sim) || { echo "FAIL: no iOS iPhone simulator found" >&2; return 1; }
  xcrun simctl list devices | grep -q "$udid" || { echo "FAIL: simulator $udid not found (ORCH_E2E_SIM_UDID)" >&2; return 1; }
  if [[ -e "$root/.orch-dev-sandbox" ]]; then dp down --root "$root" >/dev/null 2>&1 || { echo "FAIL: stale sandbox $root; stop it by hand" >&2; return 1; }; fi
  if [[ -e "$root" ]]; then rm -rf "$root"; fi # a leftover of an earlier run, by exact path (dev-pair never adopts a path)
  rm -rf "$work"
  (umask 077 && mkdir -p "$work") || return 1
  nonce=$(spa_nonce)

  # -- build (ONE simulator; no parallel testing)
  local xbase=(xcodebuild -project "$mobile/Orch.xcodeproj" -scheme OrchDevSandbox -destination "id=$udid" -derivedDataPath "$dd"
    -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1)
  if [[ "$(xcrun simctl list devices | grep "$udid" | grep -c Booted)" -eq 0 ]]; then xcrun simctl boot "$udid" >/dev/null 2>&1 || true; fi
  if (cd "$mobile" && xcodegen generate >"$work/xcodegen.log" 2>&1 && "${xbase[@]}" build-for-testing >"$work/build.log" 2>&1); then
    step_pass "build (OrchDevSandbox, build-for-testing)"
  else
    step_fail "build (see $work/build.log)"
    return 1
  fi

  # -- invite: the restricted key can only run `invite create`; the invite is written to a 0600 file, never to the terminal
  local sshopts=(-i "$key" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=20)
  [[ -n "${ORCH_E2E_KNOWN_HOSTS:-}" ]] && sshopts+=(-o "UserKnownHostsFile=$ORCH_E2E_KNOWN_HOSTS" -o StrictHostKeyChecking=yes)
  # shellcheck disable=SC2029 # $host is the destination, there is no remote command (the forced command runs)
  if (umask 077 && ssh "${sshopts[@]}" "$host" >"$invite" 2>"$work/ssh.log") && [[ -s "$invite" ]]; then
    step_pass "invite (one relay.dev invite in a 0600 file)"
  else
    step_fail "invite (ssh to the invite host failed; see $work/ssh.log)"
    return 1
  fi

  # -- up, in the background: --expect-code-from <root>/codes (dev-pair creates the FIFO)
  (cd "$core" && exec "$py" scripts/dev-pair up --root "$root" --relay "$relay" --invite-file "$invite" --sim-convenience \
    --scopes look,decide --expect-code-from "$root/codes") >"$work/up.log" 2>&1 &
  up_pid=$!
  local i
  for ((i = 0; i < 600; i++)); do
    [[ -f "$root/pair.json" ]] && break
    kill -0 "$up_pid" 2>/dev/null || break
    sleep 1
  done
  if [[ -f "$root/pair.json" ]]; then
    step_pass "up (sandbox started, pair.json written)"
  else
    step_fail "up (no pair.json; see $work/up.log)"
    tail -n 15 "$work/up.log" >&2
    return 1
  fi
  sleep 1 # pair.json is written before the offer is armed: a moment
  local link
  link=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["link"])' "$root/pair.json") || { step_fail "link (unreadable pair.json)"; return 1; }
  step_pass "link (pair link read; never printed)"

  # -- the phone: the UI test, with the link, the codes path and the nonce only in its environment
  env "TEST_RUNNER_ORCH_E2E_LINK=$link" "TEST_RUNNER_ORCH_E2E_CODES=$root/codes" "TEST_RUNNER_ORCH_E2E_NONCE=$nonce" \
    "${xbase[@]}" test-without-building -only-testing:OrchDevSandboxUITests/E2EPairAnswerTests/testPairAndAnswer \
    </dev/null >"$work/xcodebuild.log" 2>&1 &
  xb_pid=$!
  link=""
  # Fallback: relay the stdout code lines into the FIFO (after a grace period for the test's own file write); a duplicate is dropped by dev-pair.
  (
    local seen=0 n line out
    while kill -0 "$xb_pid" 2>/dev/null || ((seen == 0)); do
      n=0
      while IFS= read -r line; do
        n=$((n + 1))
        ((n > seen)) || continue
        out=$(spa_code_line "$line") || continue
        sleep 3
        spa_fifo_write "$root/codes" "$out" 2>/dev/null || true
        seen=$n
      done < <(grep -a '^ORCH_E2E_CODE ' "$work/xcodebuild.log" 2>/dev/null || true)
      kill -0 "$xb_pid" 2>/dev/null || break
      sleep 1
    done
  ) &
  relay_pid=$!
  step_pass "phone (UI test started)"

  # -- up finishes when the pairing is approved
  local up_deadline=$((SECONDS + 900))
  while kill -0 "$up_pid" 2>/dev/null; do
    if ((SECONDS > up_deadline)); then step_fail "up (pairing not approved within 900 s; see $work/up.log)"; return 1; fi
    if ! kill -0 "$xb_pid" 2>/dev/null; then # the UI test ended before the pairing did
      sleep 3
      kill -0 "$up_pid" 2>/dev/null && { step_fail "up (the UI test ended first; see $work/xcodebuild.log)"; return 1; }
    fi
    sleep 1
  done
  wait "$up_pid" && rc=0 || rc=$?
  up_pid=""
  if ((rc != 0)); then
    step_fail "up (pairing not approved, exit $rc; see $work/up.log)"
    tail -n 15 "$work/up.log" >&2
    return 1
  fi
  step_pass "up (pairing approved)"

  # -- ask and check on the Mac
  if out=$(dp ask --root "$root" --nonce "$nonce" 2>"$work/ask.err"); then
    step_pass "ask ($out)"
  else
    step_fail "ask (see $work/ask.err)"
    cat "$work/ask.err" >&2
    return 1
  fi
  if out=$(dp check-answer --root "$root" --nonce "$nonce" --timeout "$ask_timeout" 2>"$work/check.err"); then
    step_pass "answer ($out)"
  else
    step_fail "answer ($out; see $work/check.err)"
  fi

  # -- the UI test must have seen the settlement too
  # xcodebuild can linger after the test ended (result bundle, simulator teardown): the log's own verdict counts after 20 s.
  local waited=0 done_at=0 verdict=""
  while kill -0 "$xb_pid" 2>/dev/null && ((waited < 300)); do
    if grep -aq "Executed 1 test, with 0 failures" "$work/xcodebuild.log" 2>/dev/null; then
      ((done_at > 0)) || done_at=$waited
      ((waited - done_at >= 20)) && { verdict=log; break; }
    fi
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$xb_pid" 2>/dev/null; then
    kill "$xb_pid" 2>/dev/null || true # our own PID
    if [[ "$verdict" == log ]]; then step_pass "xcodebuild (UI test passed; xcodebuild did not exit, stopped after 20 s)"; else step_fail "xcodebuild (still running after 300 s)"; fi
    xb_pid=""
  else
    wait "$xb_pid" && rc=0 || rc=$?
    xb_pid=""
    if ((rc == 0)); then step_pass "xcodebuild (UI test passed)"; else step_fail "xcodebuild (exit $rc; see $work/xcodebuild.log)"; fi
  fi

  if ((failed == 0)); then echo "sim-pair-answer: PASS"; else echo "sim-pair-answer: FAIL" >&2; fi
  return "$failed"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -uo pipefail
  run_scenario
fi
