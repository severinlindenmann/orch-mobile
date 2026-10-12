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
| 16 | Large text, dark mode | delegated to Simulator validation | Simulator PASS (2026-10-12), partial: share-extension screen not covered | branch test/step16-large-text-dark |
| 17 | Key custody label | PASS ("Secure Enclave", label only) | | |
| 18 | Locked key | UNVERIFIED (no hardware diagnostics) | | |
| 19a | Remove with "Pretend offline" | FAIL ("Remove incomplete") | build 4: PASS | #55, #60 |
| 19b | Leave Demo | PASS | | |
| 19c | Reset this iPhone | PASS | | |
| 20 | Destructive passcode/reinstall | UNVERIFIED (not run) | | |

Every failure from session 1 is fixed on device as of build 5. Still open:
- 13/14 untested;
- 16 validated on the Simulator only (share-extension screen and a real device pass still open);
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

## Step 16: large text and dark mode (Simulator, 2026-10-12)

Simulator evidence only (iPhone Simulator, Demo stack). `UITests/LargeTextDarkTests.swift` runs XL, XXXL and AX5 (accessibilityXXXL),
each in light and dark: Home (incl. scrolled to the end above the tab bar), question options (no "…"), sign sheet normal and the
unsafe-content Demo question (hidden-character chips, single warning, hosted marker not squeezed, Sign enabled and hittable after
scrolling to the end, Cancel reachable, unsafe options refused sheet), Drop list and compose sheet, Pairing entry and compare screen,
Settings (last row above the tab bar), workspace Settings incl. Demo controls (Leave reachable) and a client-hosted workspace.
Each screen asserts element reachability and that nothing runs past the screen edges; XL, XXXL and AX5 all end with 0 failures.
Screenshots: `docs/screens/step16-<screen>-ax5-<theme>.png` (AX5 only; the XL and XXXL runs passed but their screenshots were not kept).

Bugs found and fixed (restyle only; signed text, SafeText rules and arming/scroll-to-end gating untouched):
- Sign sheet, unsafe content: the pinned footer's warning block was truncated ("Check it before you…") and left too little scroll area;
  at XXXL the pinned footer left a third of the screen. The footer now joins the scroll content from XL (unsafe) / XXXL (always).
- AX5 Home: the one-row header ran wider than the screen and pushed the whole page past both edges; it now stacks. DemoChip wraps.
- AX5 workspace cards: a long chip laid out on one line wider than the card; FlowLayout now bounds chips to the row.
- AX5 Pairing: the pinned Demo bar took about half the screen and truncated; it now scrolls with the content.

Not covered: the share extension error/Details screen (needs the system share sheet; not reachable via a test hook in this run).
Test-only: `--hold-reconcile` launch flag (DEBUG) disables the timed background reconcile (see flaky test below).

Flaky `testReopenedPendingSubmissionKeepsSubmittedOption`: root cause was the app's own timed background reconcile of the stored
decision (20 s in UI tests), which could settle the decision mid-test (before the test pressed "Check again"), removing the pending
row the test was waiting on. The test now launches with `--hold-reconcile` and waits for state with 30 s timeouts. 10 of 10 passed
before the fix in one local loop (the race is timing dependent) and 10 of 10 after; the fix removes the timer race rather than relying on luck.
