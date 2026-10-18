#!/usr/bin/env bash
# sim-pair-answer helpers: the code-line filter (the stdout fallback must pass only well-formed lines), the root length rule, the nonce.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sim-pair-answer.sh
. "$HERE/sim-pair-answer.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

offer=0123456789abcdef0123456789abcdef
[[ "$(spa_code_line "ORCH_E2E_CODE $offer sas AB12cd")" == "$offer sas AB12cd" ]] || fail "sas line"
[[ "$(spa_code_line "ORCH_E2E_CODE $offer cert_code 123456")" == "$offer cert_code 123456" ]] || fail "cert_code line"
for bad in "" "ORCH_E2E_CODE" "ORCH_E2E_CODE $offer sas AB12c" "ORCH_E2E_CODE $offer sas AB12cde" "ORCH_E2E_CODE $offer pin AB12cd" \
  "ORCH_E2E_CODE ${offer}0 sas AB12cd" "ORCH_E2E_CODE ${offer^^} sas AB12cd" "ORCH_E2E_CODE $offer sas AB12c! " "ORCH_E2E_CODE $offer sas AB12cd x" \
  "xORCH_E2E_CODE $offer sas AB12cd" "ORCH_E2E_CODE $offer sas AB12;d"; do
  if spa_code_line "$bad" >/dev/null; then fail "accepted: $bad"; fi
done

spa_root_ok "/Users/severin/.cache/orch-rh-e2e/run/spa-sbx" || fail "a normal root was refused"
long=$(printf 'x%.0s' $(seq 1 53))
if spa_root_ok "$long"; then fail "a 53-byte root was accepted"; fi
spa_root_ok "$(printf 'x%.0s' $(seq 1 52))" || fail "a 52-byte root was refused"

n1=$(spa_nonce)
n2=$(spa_nonce)
[[ "$n1" =~ ^[0-9a-f]{8}$ && "$n2" =~ ^[0-9a-f]{8}$ && "$n1" != "$n2" ]] || fail "nonce: $n1 $n2"

# the non-blocking FIFO write: fails at once with no reader, delivers one line with a reader
d=$(mktemp -d "${TMPDIR:-/tmp}/spa.XXXXXX")
trap 'rm -f "$d/f"; rmdir "$d"' EXIT
mkfifo "$d/f"
if spa_fifo_write "$d/f" "x" 2>/dev/null; then fail "write without a reader succeeded"; fi
exec 3<>"$d/f"
spa_fifo_write "$d/f" "hello" || fail "write with a reader failed"
IFS= read -r -t 2 got <&3 || fail "nothing arrived"
exec 3>&-
[[ "$got" == hello ]] || fail "got: $got"
echo "ok: code-line filter, root length, nonce, fifo write"
