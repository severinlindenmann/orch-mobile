# iPhone e2e report (Demo mode, TestFlight)

The owner's hands-on sessions on a real iPhone, run against the in-app Demo host and relay (FakeHost/FakeRelay).
This is Demo evidence only: it says nothing about the real relay, a real host or production APNs. Those are the
provisional P3 scenarios in [plug-in.md § E](plug-in.md#e-contract-and-p3-end-to-end-tests).

Device for every session: iPhone 15, iOS 26.6.2. Builds come from the internal TestFlight group "Owner".

| Build | Version (build) | develop | Date |
|---|---|---|---|
| 2 | 0.1.0 (261011.104943) | — | 2026-10-11 (session 1, full checklist) |
| 4 | 0.1.0 (261012.83044) | d48d50c | 2026-10-12 (re-test) |
| 5 | 0.1.0 (261012.104950) | 650cff5 | 2026-10-12 (re-test) |

Build 3 (from f7cd52d) was uploaded but not handed out, because develop CI was red on that commit.

## Results

| Step | What | Session 1 (build 2) | Re-tests | Fixed by |
|---|---|---|---|---|
| 1 | Install, launch | PASS | | |
| 2 | Demo marking | PASS | | |
| 3 | Home, Needs you, workspace | PASS | | |
| 4 | Sign sheet | PASS (UX note a) | | |
| 5 | Long text, arming | PASS (UX note c) | | |
| 6 | Hidden characters | PASS (UX note d) | | |
| 7 | Leave while reviewing | PASS | | |
| 8 | Pairing via Demo panels | UNVERIFIED (code comparison not separately confirmed) | | |
| 9a | Wrong key echoed | PASS | | |
| 9b | R1 attack alarm | FAIL (paired without alarm) | build 4: PASS | #54 |
| 10a | Reject | PASS (UX note b) | | |
| 10b | Primary offline, expiry | FAIL (no primary step) | build 4: PASS | #54 |
| 11 | Drop in app | PASS | | |
| 12 | Share from Photos/Files/Safari | FAIL (not in share sheet, then "orch can't read its workspaces") | build 4: FAIL; build 5: PASS | #51, #62 |
| 13 | Large share | blocked by 12 | not tested (optional) | |
| 14 | Lock during share | blocked by 12 | not tested (optional) | |
| 15 | Notifications | FAIL (no discoverable trigger) | build 4: arrives, not replaced; build 5: PASS | #55, #63 |
| 16 | Large text, dark mode | delegated to Simulator validation | open | |
| 17 | Key custody label | PASS ("Secure Enclave", label only) | | |
| 18 | Locked key | UNVERIFIED (no hardware diagnostics) | | |
| 19a | Remove with "Pretend offline" | FAIL ("Remove incomplete") | build 4: PASS | #55, #60 |
| 19b | Leave Demo | PASS | | |
| 19c | Reset this iPhone | PASS | | |
| 20 | Destructive passcode/reinstall | UNVERIFIED (not run) | | |

Every failure from session 1 is fixed on device as of build 5. Still open:
- 13/14 untested;
- 16 not yet validated;
- 18/20 unverified on hardware;
- 8: the explicit code comparison is unconfirmed.

## Why the device found what the Simulator did not

- **12, share index.** On a device the App Group container lives under `/private/var/…`. `standardizedFileURL` strips
  `/private` only for paths that exist, so the app refused its own publish of `targets.json`. Simulator paths have no
  `/private`. `DeviceConditionsTests` now runs with a `/private` root, and the "Share targets status" diagnostic
  (Settings → Demo controls, and Details in the share extension) names the cause on device.
- **15, notification replacement.** The Demo posts local notifications, and iOS never runs a Notification Service
  Extension for those. The app now replaces delivered notifications itself through the shared `NotificationReconciler`.
- **19a, Leave.** Two causes:
  - local removal depended on the host being reachable (#55);
  - for a client-hosted workspace the header layout pushed the Leave row out of the lazy form (#60).

## UX notes from session 1 (tracked in the visual refresh, #44)

- a. The "Reading the question…" transitional sheet had broken styling: a narrow dark middle column with lighter
  side panels.
- b. "Not approved on your Mac" (pairing rejection) is shown in green; it should be warning styling.
- c. Long monospaced question text is "visually painful". The exact-text and scroll-to-end rules stay.
- d. Hidden-character chips wrap in the middle of a chip.
