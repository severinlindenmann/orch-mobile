#!/bin/bash
# Builds scripts/make-push-fixture.swift against the OrchProtocol sources (one module, no package build needed) and runs it.
set -euo pipefail
cd "$(dirname "$0")/.."
bin="${TMPDIR:-/tmp}/orch-make-push-fixture"
swiftc -O -parse-as-library -module-name PushFixtureTool -package-name orchkit -D SCRIPT_BUILD \
  OrchKit/Sources/OrchProtocol/*.swift OrchKit/Tests/OrchPushFixtures/PushFixtures.swift scripts/make-push-fixture.swift -o "$bin"
exec "$bin" "$@"
