#!/usr/bin/env bash
# Refresh the vendored hub contract vectors in OrchKit/Tests/OrchTestVectors/ from an orch-hub ref:
#   vectors_hub.json    the hub's vectors/vectors_hub.json (byte for byte)
#   vectors_hub.SOURCE  hub_repo, hub_commit, vectors_hub_sha256 (HubVectorTests checks it against the file)
# Land it as one PR that changes nothing else. Usage: scripts/sync-hub-vectors.sh [ref] (default origin/develop);
# ORCH_HUB_DIR overrides the clone path.
set -euo pipefail
ref="${1:-origin/develop}"
hub="${ORCH_HUB_DIR:-$HOME/orch-dev/orch-hub}"
dest="$(cd "$(dirname "${BASH_SOURCE[0]}")/../OrchKit/Tests/OrchTestVectors" && pwd)"
git -C "$hub" fetch -q
sha="$(git -C "$hub" rev-parse "$ref^{commit}")"
tmp="$(mktemp "$dest/.sync.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
git -C "$hub" show "$sha:vectors/vectors_hub.json" > "$tmp"  # a git failure leaves the vendored file untouched
digest="$(shasum -a 256 "$tmp" | cut -d' ' -f1)"
mv "$tmp" "$dest/vectors_hub.json"
printf 'hub_repo: orch-hub\nhub_commit: %s\nvectors_hub_sha256: %s\n' "$sha" "$digest" > "$dest/vectors_hub.SOURCE"
echo "synced vectors_hub.json from orch-hub $sha"
