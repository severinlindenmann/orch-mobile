#!/bin/bash
# Negative tests: the checker must fail on a bad entitlement or a forbidden import.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fresh_copy() {
  rm -rf "$tmp/repo"; mkdir "$tmp/repo"
  tar --exclude=.build --exclude=.git --exclude=Orch.xcodeproj -cf - . | tar -xf - -C "$tmp/repo"
}
expect_failure() {
  if (cd "$tmp/repo" && scripts/check-extension-links.sh >"$tmp/out" 2>&1); then
    echo "FAIL: checker accepted: $1"; cat "$tmp/out"; exit 1
  fi
  echo "ok: checker rejected $1"
}

fresh_copy
sed -i.bak 's/group.io.severin.orch.share/group.io.severin.orch/' "$tmp/repo/ShareExtension/OrchShare.entitlements"
expect_failure "share extension with wrong app group"

fresh_copy
sed -i.bak 's#</dict>#<key>keychain-access-groups</key><array><string>x.io.severin.orch.push</string></array></dict>#' "$tmp/repo/ShareExtension/OrchShare.entitlements"
expect_failure "share extension with keychain-access-groups"

fresh_copy
sed -i.bak 's#<string>group.io.severin.orch</string>#<string>group.io.severin.orch</string><string>group.evil</string>#' "$tmp/repo/NotificationService/OrchNotify.entitlements"
expect_failure "notification service with extra app group"

fresh_copy
printf 'import CryptoKit\n' >> "$tmp/repo/NotificationService/NotificationService.swift"
expect_failure "forbidden import CryptoKit in extension"
fresh_copy
printf 'import OrchCustody\n' >> "$tmp/repo/OrchKit/Sources/OrchPush/PushHandler.swift"
expect_failure "OrchPush importing OrchCustody (signing code in the extension closure)"

fresh_copy
printf 'import OrchStore\n' >> "$tmp/repo/OrchKit/Sources/OrchPush/PushHandler.swift"
expect_failure "OrchStore (SQLite) in the extension closure"

fresh_copy
printf 'import OrchFakeHost\n' >> "$tmp/repo/NotificationService/NotificationService.swift"
expect_failure "FakeHost in the extension"

fresh_copy
printf 'import OrchProtocol\n' >> "$tmp/repo/ShareExtension/ShareViewController.swift"
expect_failure "share extension importing OrchProtocol (CryptoKit closure)"

fresh_copy
printf 'import CryptoKit\n' >> "$tmp/repo/OrchKit/Sources/OrchShareStaging/Manifest.swift"
expect_failure "CryptoKit inside a module the share extension links"

fresh_copy
sed -i.bak 's/products: \[OrchUI, OrchCoordination, OrchShareStaging\]/products: [OrchUI, OrchCoordination, OrchShareStaging, OrchCustody]/' "$tmp/repo/project.yml"
expect_failure "share extension linking OrchCustody"
fresh_copy
printf 'import struct OrchCustody.DeviceKey\n' >> "$tmp/repo/ShareExtension/ShareViewController.swift"
expect_failure "kind-qualified import of OrchCustody in the share extension"

fresh_copy
printf 'import struct CryptoKit.SHA256\n' >> "$tmp/repo/ShareExtension/ShareViewController.swift"
expect_failure "kind-qualified import of CryptoKit in the share extension"

fresh_copy
printf 'import CommonCrypto\n' >> "$tmp/repo/ShareExtension/ShareViewController.swift"
expect_failure "CommonCrypto import in the share extension"

fresh_copy
printf 'let s = URLSession.shared\n' >> "$tmp/repo/ShareExtension/ShareViewController.swift"
expect_failure "URLSession in the share extension"

fresh_copy
printf 'func f() { _ = SecItemAdd }\n' >> "$tmp/repo/OrchKit/Sources/OrchShareStaging/Manifest.swift"
expect_failure "SecItem in a module the share extension links"

fresh_copy
printf 'import struct CryptoKit.SHA256\n' >> "$tmp/repo/OrchKit/Sources/OrchCoordination/Tombstones.swift"
expect_failure "kind-qualified CryptoKit import in OrchCoordination (linked by the share extension)"
fresh_copy
sed -i.bak 's/products: \[OrchUI, OrchCoordination, OrchShareStaging\]/products: [OrchUI, OrchCoordination, OrchShareStaging, OrchStore]/' "$tmp/repo/project.yml"
expect_failure "share extension linking OrchStore (SQLite)"

fresh_copy
printf 'import OrchStore\n' >> "$tmp/repo/OrchKit/Sources/OrchShareStaging/Manifest.swift"
expect_failure "OrchShareStaging importing OrchStore"
echo 'Negative tests OK'
