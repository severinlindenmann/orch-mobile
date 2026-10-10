# orch mobile

Native iPhone app for orch v2 (Swift/SwiftUI). It replaces the PWA that earlier drafts planned.

orch mobile is the phone side of orch v2: pair with a workspace by QR scan, see workspace cards, answer questions
("needs you"), receive push, explicitly confirm signatures, and move files with Drop. The relay never sees plaintext.

## Decisions

Source of truth: [orch-core PR #327](https://github.com/severinlindenmann/orch-core/pull/327) (branch `docs/v2-native-ios`).

- **D45, native iPhone app.** Swift and SwiftUI, iOS 18 and later, this repo (`orch-mobile`). It has a Core Swift
  package with protocol v2, a notification service extension, a share extension and XCUITest end-to-end tests.
  It replaces the PWA (D16).
- **D46, P-256 everywhere.** The one crypto suite is protocol v2 suite 2: ECDSA P-256, ECDH P-256, HKDF-SHA-256,
  AES-256-GCM. Device keys live in the Secure Enclave (iPhone and Apple-silicon Macs), cannot be exported, and sign
  while the iPhone is unlocked (D49), after explicit confirmation in the sign sheet. Replaces D22 (Ed25519/X25519).
- **D47, TestFlight and APNs.** Builds go out through TestFlight (Apple Developer Program account). Push goes through
  APNs; the relay holds the auth key (`.p8`) on the VPS, never in a repo. App Store later, if ever.

## Layout

```
orch-mobile/
├── project.yml             XcodeGen source; Orch.xcodeproj is generated and ignored
├── App/                    SwiftUI Home/Welcome, DEBUG launch options, app entitlements
├── OrchKit/                Swift 6 package (iOS 18 / macOS 15), no third-party dependencies
│   ├── Sources/            OrchProtocol, OrchCustody, OrchStore, OrchPush, OrchClient,
│   │                       OrchFakeHost, OrchUI (tokens and shared rails)
│   └── Tests/              One unit-test target per module
├── NotificationService/    OrchNotify: generic notification fallback, completion gate
├── ShareExtension/         OrchShare: compose placeholder
├── AppTests/               Hosted unit tests
├── UITests/                Home XCUITest
├── scripts/                Extension dependency audit
└── .github/workflows/      Core and hosted-app CI
```

The NSE links only OrchPush → OrchProtocol. The share extension links only OrchUI.
All package modules compile with extension API restrictions. The app owns the `.keys`
keychain group; only the app and NSE share `.push`. The share extension has no keychain
entitlement. App Groups: `group.io.severin.orch` (app + NSE: push replay state) and
`group.io.severin.orch.share` (app + share extension: share staging), so the NSE cannot read staged files.

## Build and test

Requires Xcode 16.4 or later, Swift 6, and XcodeGen **2.46.0**. CI pins Xcode 16.4 on
`macos-15` and builds XcodeGen's pinned tag if Homebrew supplies another version.
Automatic signing uses team `77D4THRYUN`; simulator tests require no signing identity.

```sh
brew install xcodegen
xcodegen --version # expected: Version: 2.46.0
swift test --package-path OrchKit
xcodegen generate
xcodebuild -project Orch.xcodeproj -scheme Orch \
  -destination 'platform=iOS Simulator,id=B64F1C73-E1D2-42D2-980B-C0E537CD618C' \
  -derivedDataPath .build/dd CODE_SIGNING_ALLOWED=NO test
scripts/check-extension-links.sh
```

That UUID is the dedicated local iOS 18.3 simulator. Elsewhere, choose an available
simulator from `xcrun simctl list devices available`. The Orch scheme runs hosted and UI
tests locally; CI uses `build-for-testing` then `test-without-building` with
`-only-testing:OrchTests` to exclude UI tests from execution.

Debug launch arguments are parsed only by `LaunchOptions`: `--demo` opens the static
Home preview; `--ui-testing` marks a test launch. Release ignores both. With no
workspaces, Welcome offers Try Demo and Pair a workspace. Try Demo opens the same
static fixtures in either configuration.

## TestFlight

`scripts/testflight.sh` archives (Release, generic iOS), exports with method
`app-store-connect`, and optionally uploads to App Store Connect (app "Orch
Mobile", internal testing only: `testFlightInternalTestingOnly` is set).

```
scripts/testflight.sh               # same as --dry-run: archive + export a local .ipa
scripts/testflight.sh --upload      # archive + export + upload to App Store Connect
scripts/testflight.sh --add-internal  # --upload, then wait for processing and add the
                                    # build to the internal group "Owner" (created if missing)
```

- Needs a clean git tree on a commit that exists on origin; runs `xcodegen generate`.
- Marketing version comes from `MARKETING_VERSION` in `project.yml`; the build number is
  UTC `yymmdd.HHMMSS` (override with `BUILD_NUMBER=...`; 1-3 dotted integers), compared per
  component by App Store Connect. Uploads are refused unless it exceeds the latest uploaded build.
- Signing is automatic. By default xcodebuild uses the Apple account signed in to Xcode;
  `USE_API_KEY=1` makes it use the App Store Connect key at
  `~/.appstoreconnect/private_keys/AuthKey_HVML779F7U.p8` instead. The `--add-internal`
  REST calls always use that key (ES256 JWT from `scripts/asc-jwt.swift`; the key and the
  token are never printed or logged).
- Logs and the .ipa land in `.build/testflight/` (gitignored).
- Xcode's export uses rsync; the script runs it with a system-only `PATH` because a
  Homebrew rsync breaks it.
- Export compliance is intentionally not declared in the build, so a new build may show
  "Missing Compliance" until answered in App Store Connect.

## Status

M1 skeleton: Home shows Laptop and Client VM, a Needs you list, and Drop. Demo is
explicitly labelled static preview data. Pairing, transport, crypto, storage, push
processing, and share staging are not implemented. The NSE emits only app-authored
generic text; the share composer has disabled Cancel/Save controls. No security or
real-device delivery claims follow from this milestone.

Work is tracked in the issues (labels `v2`, `v2:P4-mobile`). Security-relevant changes
carry the `security-review` label and need an Opus review before merge.

## Branches

`main` is protected (PR with one approving review and code-owner review). Work happens on `develop` and in feature
branches that merge into it.

## License

MIT
