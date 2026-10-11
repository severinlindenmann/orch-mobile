# orch mobile

Native iPhone app for orch v2 (Swift/SwiftUI). It replaces the PWA that earlier drafts planned.

orch mobile is the phone side of orch v2: pair with a workspace by QR scan, see workspace cards, answer questions
("needs you"), receive push, sign with Face ID, and move files with Drop. The relay never sees plaintext.

## Decisions

Source of truth: [orch-core PR #327](https://github.com/severinlindenmann/orch-core/pull/327) (branch `docs/v2-native-ios`).

- **D45, native iPhone app.** Swift and SwiftUI, iOS 18 and later, this repo (`orch-mobile`). It has a Core Swift
  package with protocol v2, a notification service extension, a share extension and XCUITest end-to-end tests.
  It replaces the PWA (D16).
- **D46, P-256 everywhere.** The one crypto suite is protocol v2 suite 2: ECDSA P-256, ECDH P-256, HKDF-SHA-256,
  AES-256-GCM. Device keys live in the Secure Enclave (iPhone and Apple-silicon Macs), cannot be exported, and sign
  only after Face ID or Touch ID. Replaces D22 (Ed25519/X25519).
- **D47, TestFlight and APNs.** Builds go out through TestFlight (Apple Developer Program account). Push goes through
  APNs; the relay holds the auth key (`.p8`) on the VPS, never in a repo. App Store later, if ever.

## Planned layout

```
orch-mobile/
├── App/                    SwiftUI app: pairing, workspace cards, questions, Drop, settings
├── Core/                   Swift package: protocol v2 (suite 2), sealing, signatures, per-workspace storage;
│                           tested against the orch-relay protocol v2 vectors
├── NotificationService/    notification service extension: opens the sealed push payload on the device
├── ShareExtension/         share extension: send a file to a workspace through Drop
└── Tests/                  Core unit tests (vectors), UI tests including XCUITest e2e in the Simulator
```

## Status

Planning. Work is tracked in the issues (labels `v2`, `v2:P4-mobile`). Security-relevant changes carry the
`security-review` label and need an Opus review before merge.

## Branches

`main` is protected (PR with one approving review and code-owner review). Work happens on `develop` and in feature
branches that merge into it.

## License

Licensed under the PolyForm Noncommercial License 1.0.0. Commercial use requires a separate license from the author. See [LICENSE](LICENSE).
