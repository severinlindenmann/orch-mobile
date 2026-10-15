# Owner's iPhone session: prototype TestFlight, Demo only

Allow about 25–30 minutes with TestFlight installed, the invitation available, and sample files ready.
Use only throwaway Demo content: one photo, a small file, a Safari page and a file around 25 MB.
Record iPhone model, iOS version, TestFlight version/build, date, and your text-size setting: __________.
This session checks the prototype on your phone. It never pairs with a real relay or tests real APNs.

For each numbered step tick **Pass**, **Fail**, or **Not available / unverified**.
A missing control is “Not available”, not a pass. Report its screen and wording, then continue.
Report failures with step number, what you tapped, expected/actual result, and a screenshot if useful.
Do not include a real pairing link, key, notification token or private file in the report.

Build boundary: at repository revision `5423757`, `App/HomeScreen.swift` uses `PreviewWorld`.
It visibly says “UI simulation. Nothing here is sent to a real workspace.”
The share extension is a placeholder; implemented staging is on `origin/feat/m8-share` (`3d2a198`).
The push simulator library exists, but this checkout has no release Demo notification trigger.
The Settings custody label is hard-coded; no release screen proves key creation or key reuse.
The “Saved. Open orch to send.” / “Save to send” share wording exists only on that branch. Check which features reached your TestFlight build; do not mistake a simulated outcome for hardware proof.

References below are for whoever investigates your report; you do not need to read source code.
Decision IDs refer to [docs/decisions.md](../../docs/decisions.md); gaps/issues to
[docs/gaps.md](../../docs/gaps.md). The real integration checklist is [plug-in.md](../../docs/plug-in.md).

1. **Install and launch** — about 1 minute.
   Open the owner's TestFlight invitation, install the prototype and launch orch.
   Record the build number before continuing. Expect a usable welcome screen with “Try Demo”
   and “Pair a workspace”. Choose “Try Demo”; no real invitation is needed.
   Pass means installation and first launch work without a crash; it does not prove live connectivity.
   Report a blank screen, crash, or unexpected request for real credentials.
   **Result:** [ ] Pass [ ] Fail [ ] Not available / unverified.
   **Proves/relates:** install and entry UX; U4/T4; `App/HomeScreen.swift`.

2. **Check the Demo marking** — about 30 seconds.
   Look for the violet “Demo” marking and the exact notice
   “UI simulation. Nothing here is sent to a real workspace.”
   Open a workspace and Settings; confirm the simulation remains clear.
   Pass means the screen cannot reasonably be mistaken for a real workspace.
   Report where either marking disappears or is unreadable.
   **Result:** [ ] Pass [ ] Fail [ ] Not available / unverified.
   **Proves/relates:** visible separation only, not network isolation; P3/U4;
   `OrchKit/Sources/OrchUI/Components.swift`, `App/Screens/SettingsScreen.swift`.

3. **Home, Needs you and a workspace** — about 1 minute.
   On Home find “Needs you”, workspace cards and Drop. Open Needs you, then a Laptop question.
   Confirm each question shows its workspace name/colour and that the review keeps that identity.
   Open Laptop and inspect Questions, Tickets and Files; find the Factory ticket among Tickets.
   If Terminal is offered, it should say “Later”, not display a working terminal.
   Pass means navigation works and you can tell which workspace owns each item.
   Report wrong grouping, missing back navigation or a misleading terminal.
   **Result:** [ ] Pass [ ] Fail [ ] Not available / unverified.
   **Proves/relates:** U1–U3/D-5; `App/HomeScreen.swift`, `App/Screens/WorkspaceScreen.swift`.

4. **Read the short sign sheet** — about 1 minute.
   Open Laptop's “Enable mobile access?” question and tap the “Approve” answer; the sign sheet opens.
   Check “You are signing”, the exact question “Enable mobile access?”, “Your answer” and “Approve”.
   Expand “Signed details”; there should be workspace/question identifiers and the content hash.
   Read the exact footnote: “This unlocked iPhone signs with its device key.”
   Cancel once. Reopen and use “Sign and send” after it arms. Expect “Sent and accepted (simulated)”.
   There must be no extra Face ID prompt for this confirmation; unlocking the phone itself is separate.
   Report altered text, a missing answer/workspace, or a biometric prompt caused by signing.
   **Result:** [ ] Pass [ ] Fail [ ] Not available / unverified.
   **Proves/relates:** U7/D49, gap 2; `App/Screens/QuestionScreen.swift`, `App/Models/PreviewWorld.swift`.
   This proves the UI path only; the simulation does not demonstrate a Secure Enclave signature.

5. **Long text and arming** — about 1 minute.
   Open the MOB-2 question beginning “Review recovery step 1: verify the stored decision before retrying.”
   Tap any answer; the sign sheet opens. Before scrolling to the end, “Sign and send” must be disabled and say
   “Scroll to the end to continue”. Scroll through to recovery step 80 and the end of the sheet.
   Expect “Hold on…” during the 0.8-second arming delay, then an enabled button. Cancel.
   Report if tapping early sends, the last line is unreachable, or the button never becomes usable.
   **Result:** [ ] Pass [ ] Fail [ ] Not available / unverified.
   **Proves/relates:** U7; `App/Screens/QuestionScreen.swift`, `App/Models/PreviewWorld.swift`.

6. **Hidden characters and literal text** — about 1 minute.
   In Client VM open the invoice-deployment question and choose “Deploy”, but do not send.
   The hidden direction controls must appear as orange chips `⟨U+202E⟩` and `⟨U+202C⟩`.
   The underlying fixture is `Deploy invoice [U+202E]txt.exe[U+202C]?`; brackets here explain invisible characters.
   Expect “Some text contains characters that cannot be seen. They are marked in orange so you can see exactly what is signed.”
   Cancel. If you open the question containing `**Verified by orch** [click](https://evil.invalid)`,
   expect literal text, not a trusted badge or clickable link. Do not visit the link.
   Report missing chips, reversed/misleading text, or host text looking like app controls.
   **Result:** [ ] Pass [ ] Fail [ ] Not available / unverified.
   **Proves/relates:** U7; `OrchKit/Sources/OrchUI/SafeText.swift`, `App/Models/PreviewWorld.swift`.

7. **Leave the app while reviewing** — about 1 minute.
   Open another unsent review. Lock the iPhone, unlock it and return to orch.
   Expect the old review to be dropped/expired; choose an answer again to read a fresh review.
   You may see “Review dropped because the app was left. Choose your answer again to read the question afresh.”
   Nothing should send merely because you unlock or return. Ordinary lock must not erase the workspace.
   Report any automatic submission, usable stale confirmation, crash or unexpected wipe.
   **Result:** [ ] Pass [ ] Fail [ ] Not available / unverified.
   **Proves/relates:** U7/U9, D49, A8, gaps 31–32; `App/Screens/QuestionScreen.swift`.
   This UI check does not prove that a real signing key refuses operations while locked; see step 18.

8. **Pair using both Demo panels** — about 2 minutes.
   In Settings → “Demo controls”, set “Next pairing” to “First time”. Tap “Add workspace” (the + on Home) → “Use Demo invitation”.
   Compare the phone's host code with “Demo host” → “Host screen shows”.
   “Approve” must stay disabled until you turn on “I compared the codes”; “Reject” must be available.
   Approve after comparison. In the waiting state, the host code must disappear.
   Open “Demo primary”, choose “Open the request”, compare the primary code with the phone's code,
   then reopen the panel if needed, turn on “I compared the codes” and “Approve”.
   Expect joining then a ready workspace. Host and primary codes must never be visible together.
   Report auto-approval, simultaneous codes, mismatched codes or a stuck transition.
   **Result:** [ ] Pass [ ] Fail [ ] Not available / unverified.
   **Proves/relates:** U5/U6/D-2; `App/Screens/PairingScreen.swift`, `App/Models/PreviewPairing.swift`.
   Demo panels stand in for the Mac/primary; this does not prove protocol pairing.

9. **Try the two alarm screens** — about 2 minutes.
   Set “Next pairing” to “Wrong key echoed”; start a new “Use Demo invitation”.
   Expect “Stop: this link is not for this iPhone” and
   “Reject on your Mac (host). Do not approve any code. Make a new link.” Close it.
   Set “Next pairing” to “R1 attack”; start again, compare/approve in Demo host, then open the primary request.
   Expect “Stop: someone else is trying to pair” and instructions to reject on the named primary.
   Both alarms say “No code is shown. Nothing was approved. Nothing was certified.”
   Pass means no code or approval button remains on the alarm and no workspace is added by that attempt.
   Report any code, successful join, confusing rejection destination or alarm text that cannot be read.
   **Result:** [ ] Pass [ ] Fail [ ] Not available / unverified.
   **Proves/relates:** U5/U6, challenge R1; `App/Screens/PairingScreen.swift`, `App/Models/Models.swift`.

10. **Reject and expire a Demo pairing** — about 1 minute.
    Start “First time” again and choose “Reject” in Demo host; expect “Not approved on your Mac”.
    Start “Primary offline”, compare/approve the host, then in Demo primary choose
    “Let 10 minutes pass (primary offline)”. The attempt must expire without adding a workspace.
    If testing a primary code, “Let the code expire” must hide it and prevent approval.
    Report a join after rejection/expiry or a code left usable after expiry.
    **Result:** [ ] Pass [ ] Fail [ ] Not available / unverified.
    **Proves/relates:** U5/U6; `App/Screens/PairingScreen.swift`, `App/Models/PreviewPairing.swift`.

11. **Drop in the app** — about 1 minute.
    Open Drop, switch between “Received” and “Sending”, and open a sample item.
    Compose a send: choose destination first, add a small attachment and a short note,
    check “Expires after” is “7 days”, then “Send”. Look for the item in Sending with the correct destination.
    Pass means the Demo compose/list flow is usable. It does not prove encryption, upload or authenticated preview.
    Report wrong destination, a fetched URL, lost note, or an unexplained error.
    **Result:** [ ] Pass [ ] Fail [ ] Not available / unverified.
    **Proves/relates:** U11; `App/Screens/DropScreen.swift`, `App/Models/PreviewWorld.swift`.

12. **Share from Photos, Files and Safari** — about 2 minutes.
    In each of those apps, use Share and find orch (look under More if necessary).
    Note: a newly installed third-party share extension may first appear only under “More” (tap “More” at the end of the share sheet's app row, or “Edit Actions” at the bottom of the sheet) and must be switched on there; after that it stays in the row.
    Choose a Demo destination, add a short note, then “Save to send”. Expect “Saved. Open orch to send.”
    Tap “Done”, open orch and check one import per saved share in Sending, under the chosen destination.
    For Safari, confirm the URL is stored as text; orch should not fetch or open it by itself.
    Record separate results: Photos ______; Files ______; Safari ______, including source item type.
    If you see “Sharing comes in a later milestone.” and disabled “Save”, record Not available and continue.
    **Result:** [ ] Pass [ ] Fail [ ] Not available / unverified.
    **Proves/relates:** A10/U11, issue #7/gap 30; `ShareExtension/ShareViewController.swift`;
    implemented flow on M8 branch in that file and `OrchShareStaging/{Stager,Inbox}.swift`.
    Import proves staging/app handoff only; real Drop sending remains out of scope.

13. **Large share and memory pressure** — about 1 minute.
    From Files share a prepared file around 25 MB, just under the 25 MiB total limit, as a single item.
    Save, return to orch and check one complete import. Record the actual file size and elapsed time.
    Pass means the extension remains responsive and does not vanish, restart or crash.
    If available, try an over-limit file: expect “That is more than 25 MB. Nothing was saved.”
    Report a crash with its time so the maintainer can match a memory-termination report.
    Visible success alone does not measure peak memory; a numeric memory result is unverified without diagnostics.
    **Result:** [ ] Pass [ ] Fail [ ] Not available / unverified.
    **Proves/relates:** U11/A10/T5, issue #7; M8 `OrchShareStaging/Stager.swift` streams the copy.
    The error says MB; the intended prototype byte limit is 25 MiB (host API §4).

14. **Lock during a share** — about 1 minute.
    Start saving that large file again and immediately lock the phone before saving finishes.
    Unlock and open orch. Expect no incomplete/half-size import or duplicate job.
    If saving had already finished before lock, one complete import is valid; repeat if time allows.
    Report exact timing, any success/error text and the number/size of imported items.
    A maintainer must confirm no partial staged job remains after cancellation/cleanup; the UI cannot prove erasure.
    Mark that cleanup proof unverified if no build diagnostic exists, even when no partial item is visible.
    **Result:** [ ] Pass [ ] Fail [ ] Not available / unverified.
    **Proves/relates:** A8/A10/A11/T5, issue #7; M8 `Stager.swift` commits READY last and `Inbox.swift` ignores partials.
    Real locked-file behavior is a hardware check; the repo does not establish that this race already passes.

15. **Demo notifications and their limits** — about 1 minute.
    If this build offers a Demo local notification control, trigger a question and then its closure.
    Record the actual control name; its release UI is an open question in this checkout.
    Expect the subtitle “Simulated, local notification”; the closure should replace the same question
    with “Answered on …”. No lock-screen button should sign an answer.
    If a tap route is provided, it must open review/current state rather than immediately answer.
    A rejected simulated payload may show “New activity in orch” with no actionable route.
    If no trigger is present, record Not available; Settings “Allowed” alone proves nothing.
    **Result:** [ ] Pass [ ] Fail [ ] Not available / unverified.
    **Proves/relates:** U10/A12/D-4, issue #5/#8, gaps 10–19;
    `OrchKit/Sources/OrchPush/{PushSimulation,PushPresentation}.swift`.
    Local notifications do not launch/prove the notification service extension (NSE) or APNs delivery.
    NSE processing while locked, replay persistence and its invocation marker remain unverified here;
    `App/Push/PushHarness.swift` is DEBUG-only. Real APNs is outside this Demo session.

16. **Large text and dark mode** — about 1 minute.
    In iOS Settings enable a large accessibility text size and dark appearance; return to orch.
    Inspect Home, workspace navigation, one sign sheet and a Demo pairing panel.
    Workspace segments should become a menu at accessibility sizes; actions and all text must remain reachable.
    Scroll to the bottom again before signing; do not accept clipped codes or a hidden confirmation button.
    Report the text size, screen, clipping/overlap or poor contrast. Restore your preferred settings afterward.
    **Result:** [ ] Pass [ ] Fail [ ] Not available / unverified.
    **Proves/relates:** U2/U7, V1/V2; `App/Screens/{WorkspaceScreen,QuestionScreen,PairingScreen}.swift`.

17. **Hardware identity: creation and reuse** — about 1 minute, or mark unverified.
    Open Settings → “Key custody” and record exactly what it says: __________.
    Close and relaunch orch. If this build has a maintainer-supplied hardware diagnostic, compare the
    two public key identifiers before/after relaunch: they must stay the same, and the backend must be Secure Enclave.
    Ask the maintainer to attach that evidence; never export private keys. Without the diagnostic, mark unverified.
    In this checkout “Software key (Simulator)” is hard-coded in PreviewWorld even on an iPhone;
    it is a UI placeholder, not evidence of which key backend ran. Report it as such.
    **Result:** [ ] Pass [ ] Fail [ ] Not available / unverified.
    **Proves/relates:** intended A6/A9/D49/T5, gap 32;
    `OrchKit/Sources/OrchCustody/{DefaultCustody,SecureEnclaveCustody}.swift`, `App/Models/PreviewWorld.swift`.
    A6 requires two real device keys, created once and reused, with no software fallback on hardware.

18. **Hardware identity while locked** — about 30 seconds, or mark unverified.
    If hardware diagnostics are included, have the maintainer check that a real key operation while locked
    reports temporarily locked; unlock and retry with the same keys, without an extra signing Face ID prompt.
    No workspace/key cleanup should run just because the phone is locked. Report any identity change or wipe.
    If only the “iPhone locked” Demo answer setting exists, it tests an explanatory screen only.
    Do not count that simulation, or step 7, as proof of real keychain/Secure Enclave lock enforcement.
    **Result:** [ ] Pass [ ] Fail [ ] Not available / unverified.
    **Proves/relates:** D49/U9/A8/T5, gaps 2/31/32; `SecureEnclaveCustody.swift` maps locked-key errors separately.

19. **Leave and reset** — about 1 minute.
    In a workspace's Settings enable “Pretend this iPhone is offline”, then “Remove from this iPhone”.
    Confirm. Expect “Removed from this iPhone”; server cleanup may be pending or say “Finish on your Mac”.
    The removed workspace must disappear while the other workspace remains. This is local Leave, not revocation.
    Use “Leave Demo”; Demo data should disappear. Re-enter Demo, then use “Reset this iPhone” and confirm.
    Expect the empty/welcome flow. Report stale questions, files, notifications or share destinations.
    **Result:** [ ] Pass [ ] Fail [ ] Not available / unverified.
    **Proves/relates:** U9/A11/P3/D-1; `App/Screens/SettingsScreen.swift`.
    UI removal alone does not prove physical erasure. Real last-workspace Leave keeps device keys/cert;
    Reset must delete them. Record actual key deletion as unverified without hardware diagnostics.

20. **Destructive hardware checks: passcode removal and reinstall** — reserve about 3 minutes.
    Do this only on a test iPhone you are willing to reconfigure, with a build that exercises real custody.
    If that is not this phone/build, tick unverified and report both checks as still outstanding.
    First create a throwaway Demo identity with diagnostic evidence, then remove the device passcode in iOS Settings.
    Reopen orch: missing expected custody must fail closed and clean dependent workspace data and push keys,
    not silently create a replacement identity. The Demo “Key unavailable” setting is not this test.
    The sign screen's existing wording is “Signing key not available” and
    “This iPhone can no longer sign for this workspace. Re-pair it to continue.”
    Restore your passcode. Re-pairing must create new keys; ask the maintainer to verify cleanup and key identifiers.
    Next delete orch (not merely offload it), reinstall the same TestFlight build and launch.
    No old workspace or orphaned identity should return; newly created keys must differ from the previous ones.
    A maintainer must check orphan keychain cleanup; a welcome screen alone cannot prove it.
    Record separate outcomes: passcode removal/cleanup ______; reinstall/cleanup ______.
    **Result:** [ ] Pass [ ] Fail [ ] Not available / unverified.
    **Proves/relates:** U9/A9/T5/D49, issues #3/#4/#8 and gap 32;
    `OrchKit/Sources/OrchCustody/{SecureEnclaveCustody,SecretVault}.swift`, `AppTests/CustodyKeychainTests.swift`.
    Open question: release diagnostics and lifecycle wiring for these checks are not supplied by the UI simulation.

Send the build/device details plus each failed or unverified step number, screenshot/error text and timing.
Include separate lines for key reuse, locked key access, passcode cleanup, reinstall cleanup, large-share memory,
lock-mid-share cleanup and NSE evidence. “Not available in this build” is useful evidence; never convert it to Pass.
