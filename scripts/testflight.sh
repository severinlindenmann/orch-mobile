#!/usr/bin/env bash
# Archive + export (+ upload) orch mobile to TestFlight (internal testing only).
#   scripts/testflight.sh [--dry-run] [--upload] [--add-internal]
# Default is --dry-run: archive and export a local .ipa, no upload.
# --add-internal: after upload, wait for processing and add the build to the
# internal beta group "Owner" (created if missing). Implies --upload.
# Env: BUILD_NUMBER overrides the generated build number.
set -euo pipefail

TEAM=77D4THRYUN
APP_ID=6820602317
KEY_ID=HVML779F7U
ISSUER=8f9968b2-a219-4890-8574-0822ad510d85
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
GROUP_NAME=Owner

MODE=dry-run; ADD_INTERNAL=0
for a in "$@"; do case "$a" in
  --dry-run) MODE=dry-run ;;
  --upload) MODE=upload ;;
  --add-internal) MODE=upload; ADD_INTERNAL=1 ;;
  -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
  *) echo "unknown flag: $a" >&2; exit 2 ;;
esac; done

ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
OUT="$ROOT/.build/testflight"; mkdir -p "$OUT"
LOG="$OUT/testflight.log"; : > "$LOG"
say() { echo "[testflight] $*" | tee -a "$LOG" >&2; }
die() { say "ERROR: $*"; exit 1; }

[ -f "$KEY_PATH" ] || die "API key not found at $KEY_PATH"
KEY_MODE=$(stat -f %Lp "$KEY_PATH"); [ "$KEY_MODE" = 600 ] || say "WARNING: key file mode is $KEY_MODE, expected 600"
command -v jq >/dev/null || die "jq missing"

# Preconditions: clean tree, HEAD on origin.
[ -z "$(git status --porcelain)" ] || die "working tree not clean"
git fetch --prune origin --quiet
git branch -r --contains HEAD --list 'origin/*' | grep -q . || die "HEAD $(git rev-parse --short HEAD) is not on any origin branch (push first)"

command -v xcodegen >/dev/null || die "xcodegen missing"
xcodegen generate --quiet >>"$LOG" 2>&1

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' project.yml | head -1)
[ -n "$VERSION" ] || die "MARKETING_VERSION not found in project.yml"
# --- App Store Connect API helpers (internal group only) ---
# A fresh JWT (15 min lifetime) is minted per call and only passed to curl via
# stdin config, so it never reaches argv, logs or a long-lived variable.
api() { # method path [json-body]; prints body, then HTTP code on the last line
  local m=$1 p=$2 b=${3:-} tok
  tok=$(swift "$ROOT/scripts/asc-jwt.swift" "$KEY_PATH" "$KEY_ID" "$ISSUER") || die "jwt failed"
  local args=(-sS --max-time 60 --retry 3 -X "$m" "https://api.appstoreconnect.apple.com$p" -H "Content-Type: application/json" -w '\n%{http_code}')
  [ -n "$b" ] && args+=(-d "$b")
  printf 'header = "Authorization: Bearer %s"\n' "$tok" | curl -K - "${args[@]}" || die "curl failed: $p"
}
body() { sed '$d'; }
code() { tail -1; }
ver_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" = "$1" ]; }

# Build number: UTC "yymmdd.HHMMSS" (two integer components, each well below
# INT32, second precision avoids same-minute collisions). ASC compares
# components numerically, so it increases per upload.
BUILD=${BUILD_NUMBER:-$(date -u +%y%m%d).$((10#$(date -u +%H%M%S)))}
[[ "$BUILD" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "invalid BUILD_NUMBER '$BUILD'"
if [ "$MODE" = upload ]; then
  R=$(api GET "/v1/builds?filter%5Bapp%5D=$APP_ID&sort=-uploadedDate&limit=1")
  [ "$(echo "$R" | code)" = 200 ] || die "latest-build query failed: HTTP $(echo "$R" | code)"
  LATEST=$(echo "$R" | body | jq -r '.data[0].attributes.version // empty')
  if [ -n "$LATEST" ]; then
    ver_gt "$BUILD" "$LATEST" || die "build $BUILD is not greater than latest uploaded build $LATEST"
  fi
fi
say "mode=$MODE version=$VERSION build=$BUILD commit=$(git rev-parse --short HEAD)"

ARCHIVE="$OUT/Orch.xcarchive"; EXPORT="$OUT/export"
rm -rf "$ARCHIVE" "$EXPORT"
# Signing auth: by default xcodebuild uses the Xcode-signed-in Apple account.
# USE_API_KEY=1 makes xcodebuild authenticate with the ASC key instead (the key
# currently gets "Authentication failed" from xcodebuild's portal calls, so it
# is opt-in; the ASC REST API steps below always use the key).
AUTH=(-allowProvisioningUpdates)
if [ "${USE_API_KEY:-0}" = 1 ]; then
  AUTH+=(-authenticationKeyPath "$KEY_PATH" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER")
fi
# Xcode's export shells out to rsync; a Homebrew rsync earlier on PATH breaks it
# ("rsync: unexpected end of file" -> "exportArchive Copy failed"). Use system tools.
XB_PATH=/usr/bin:/bin:/usr/sbin:/sbin:$(xcode-select -p)/usr/bin

say "archiving (log: $OUT/archive.log)"
env PATH="$XB_PATH" xcodebuild archive -project Orch.xcodeproj -scheme Orch -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD" "${AUTH[@]}" >"$OUT/archive.log" 2>&1 \
  || { tail -30 "$OUT/archive.log"; die "archive failed"; }

DEST=export; [ "$MODE" = upload ] && DEST=upload
sed "s/__DESTINATION__/$DEST/" scripts/ExportOptions.plist > "$OUT/ExportOptions.plist"
say "exporting destination=$DEST (log: $OUT/export.log)"
env PATH="$XB_PATH" xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" "${AUTH[@]}" >"$OUT/export.log" 2>&1 \
  || { tail -30 "$OUT/export.log"; die "export failed"; }

if [ "$MODE" = dry-run ]; then
  ls "$EXPORT"/*.ipa >/dev/null 2>&1 || die "no .ipa produced"
  unzip -p "$EXPORT/Orch.ipa" 'Payload/Orch.app/embedded.mobileprovision' 2>/dev/null \
    | security cms -D 2>/dev/null | plutil -extract Entitlements json -o - - 2>/dev/null \
    | jq -c '{aps:."aps-environment",groups:."com.apple.security.application-groups",get_task_allow:."get-task-allow"}' | tee -a "$LOG" || true
  say "dry-run OK: $(ls "$EXPORT"/*.ipa) (version $VERSION build $BUILD)"
  exit 0
fi
say "uploaded version $VERSION build $BUILD"
[ "$ADD_INTERNAL" = 1 ] || exit 0

say "waiting for build $BUILD to finish processing"
BUILD_ID=""; STATE=""
for i in $(seq 1 60); do
  R=$(api GET "/v1/builds?filter%5Bapp%5D=$APP_ID&filter%5Bversion%5D=$BUILD&limit=1")
  [ "$(echo "$R" | code)" = 200 ] || die "builds query failed: HTTP $(echo "$R" | code)"
  BUILD_ID=$(echo "$R" | body | jq -r '.data[0].id // empty')
  STATE=$(echo "$R" | body | jq -r '.data[0].attributes.processingState // empty')
  say "poll $i: state=${STATE:-not-visible-yet}"
  [ "$STATE" = VALID ] && break
  case "$STATE" in FAILED|INVALID) die "processing ended in $STATE";; esac
  sleep 30
done
[ "$STATE" = VALID ] || die "timed out waiting for processing (state=${STATE:-none})"

R=$(api GET "/v1/apps/$APP_ID/betaGroups?filter%5Bname%5D=$GROUP_NAME&limit=50")
[ "$(echo "$R" | code)" = 200 ] || die "betaGroups query failed"
GROUP_ID=$(echo "$R" | body | jq -r --arg n "$GROUP_NAME" '[.data[]|select(.attributes.name==$n and .attributes.isInternalGroup==true)][0].id // empty')
if [ -z "$GROUP_ID" ]; then
  say "creating internal group $GROUP_NAME"
  R=$(api POST /v1/betaGroups "$(jq -nc --arg n "$GROUP_NAME" --arg a "$APP_ID" \
    '{data:{type:"betaGroups",attributes:{name:$n,isInternalGroup:true,hasAccessToAllBuilds:false},relationships:{app:{data:{type:"apps",id:$a}}}}}')")
  [ "$(echo "$R" | code)" = 201 ] || { echo "$R" | body | jq -r '.errors[]?.detail' | tee -a "$LOG"; die "group create failed"; }
  GROUP_ID=$(echo "$R" | body | jq -r .data.id)
fi
R=$(api POST "/v1/betaGroups/$GROUP_ID/relationships/builds" \
  "$(jq -nc --arg b "$BUILD_ID" '{data:[{type:"builds",id:$b}]}')")
case "$(echo "$R" | code)" in
  204|409) say "build attached to group $GROUP_NAME (HTTP $(echo "$R" | code); 409 = already attached or auto-access)";;
  *) echo "$R" | body | jq -r '.errors[]?.detail' | tee -a "$LOG"; die "attach failed";;
esac
R=$(api GET "/v1/builds/$BUILD_ID")
say "final: processingState=$(echo "$R" | body | jq -r .data.attributes.processingState) expired=$(echo "$R" | body | jq -r .data.attributes.expired)"
