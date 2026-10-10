# Codex challenge of the converged M0 decisions

Reviewed 10 October 2026: [decisions](decisions.md), [Codex proposal](proposals/codex.md), [Claude proposal](proposals/claude.md), [relay protocol v2](/Users/severin/orch-dev/orch-relay/docs/protocol-v2.md) (section references below), and [architecture D49](/Users/severin/orch-dev/orch-core/docs/architecture/orch-v2.md).
This is a design review, not evidence of implementation vulnerabilities. Consequences below describe failure modes unless identified as observed.

## Acceptances

- **U1 — accept.** A Home stack plus a cross-workspace Needs you destination is sufficient for M0. My root tabs were a navigation preference, not a trust boundary; their rejection is reasonable.
- **A7 — accept the rejection of GRDB.** A bounded SQLite wrapper is viable. Dependency size alone does not prove safety, but neither does using GRDB; the concrete obligations are below.
- **P4/A6/U7/T5 — accept D49.** One SE signing identity for decisions, login and envelopes, `WhenPasscodeSetThisDeviceOnly`, and no presence/biometry gate match D49. Separate `dk_sig`/`dk_kx` is required by §1.1, not the prohibited human/transport split. Software FakePrimary PK is a different, synthetic authority, not a device-custody fallback.
- **A9/A10 — accept plaintext staging without WK/device-key access.** It is an honest deferred-send design; the extension cannot promise upload. This does not excuse the shared-container access below.
- **V4 — accept.** The attention rail remains useful alongside words/icons; adoption of my motif is not security evidence.

## Required changes

### P3/A2/A6/A8/A9/A13 — Demo authority isolation — blocker

**Objection:** Shipping FakePrimary and a synthetic software PK in TestFlight is acceptable, but a realm prefix, `.invalid` hostname and banner are not an enforced capability boundary. A8's shared paths omit realm separation, and the lifetime/entropy of authority material is unspecified.
**Consequence:** Hypothesis: an unscoped key lookup, staged job, notification or reset can cross realms; a Demo certificate or signer can be selected by a future live session. A real SE device key does not make certification by an in-process FakePrimary trustworthy.
**Proposed change:** Generate fresh synthetic authority keys per Demo installation/reset; keep vector scalars and the Python reference out of shipped resources/code (§intro). Persist Demo authority only in protected, backup-excluded Demo storage and erase it on exit, including cached keys. Key every shared record/route/job by realm plus workspace and membership generation. Construct FakePrimary only with Demo-scoped stores/custody and an in-process transport; reject external origins and cross-realm links before any request. Add Release negative tests for real-transport reachability, live-key lookup, certificate reuse and reset scope. Never import real PK/recovery material into Demo. This provides application isolation, not a sandbox against compromise of the main process.

### A11/U9/A10/A12 — Wipe order and concurrent extensions — blocker

**Objection:** `cancel → unregister push → wipe` can wait for network before local erasure, contradicting U9. Cancelling tasks does not stop already-running NSE/share processes. A durable tombstone is insufficient unless extensions can read it and must obey it.
**Consequence:** Offline leave can retain plaintext/keys indefinitely; a share extension can publish a job after deletion, or an NSE with cached keys can display content/recreate replay state after wipe. Deleting an index row can also destroy the only cleanup record.
**Proposed change:** First durably mark `(realm, ws, generation)` removed in coordination storage accessible to each affected process, then disable targets/routes and cancel/drain writers. Serialize share publication and push replay updates against removal; recheck generation before publication/handoff. Delete scoped keys, plaintext, previews, SQLite sidecars, staged jobs, pending local and delivered notifications. Keep the tombstone outside the deleted workspace until cleanup is complete; retain generation protection against late writers/rejoin. Network deregistration is bounded best effort, separate from local success. Specify authenticated retry feasibility after key deletion; otherwise report primary cleanup required. Test crashes after every phase and concurrent NSE/share writers. A notification already handed to the OS cannot be atomically recalled by a database transaction.

### A8/A3/A10 — One App Group exposes plaintext to the NSE — should

**Objection:** Rejecting separate groups is not justified by directory names or module-import restrictions. All participants have read/write access to the group container ([Apple](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html)). `Complete` prevents locked access; it does not restrict access while unlocked.
**Consequence:** An NSE compromise while unlocked can read or alter staged personal files and destination names. Conversely, the share extension can alter push replay metadata. These are granted capabilities, not a demonstrated exploit; absence of signing/network imports does not revoke them.
**Proposed change:** Restore separate push/share App Groups: app in both, NSE only push, share extension only share. Keep realm/generation coordination in each relevant group, with the app driving resumable removal. Explicitly exclude shared staging from backup and bound plaintext/quarantine retention; quarantine must not survive an explicit workspace wipe. No keychain access for share remains the right choice.

### U9/A6/A9/A11 — Revocation and lost custody are not ordinary leave — should

**Objection:** U9 describes verified revocation through workspace wipe but does not define device-wide invalidation. The converged document also loses the proposals' passcode-removal and reinstall handling.
**Consequence:** A PK-signed device revocation can leave the same revoked identity available for another workspace/re-pair; §6.2 explicitly requires new keys. Missing passcode-protected keys can coexist with surviving push keys, plaintext and misleading cached membership.
**Proposed change:** Distinguish workspace leave/member removal from device revocation and Reset. Verified self-revocation invalidates that device identity and wipes every dependent workspace, then requires new keys. Missing expected custody fails closed and cleans dependent stores/push material; missing realm index with surviving keychain items triggers orphan cleanup. Do not mistake temporary locked-key errors for permanent key loss. Require real-device passcode-removal/reinstall tests; T5 alone is only a checklist category.

### A7/A8/A5 — SQLite wrapper safety contract — should

**Objection:** RAII and a migrations table do not specify transaction boundaries, error handling, Swift/C buffer ownership, or actor reentrancy. The risk is real but bounded, not an argument that raw sqlite3 is inherently unsafe.
**Consequence:** A temporary Swift buffer bound with the wrong lifetime can be read after release; ignored `BUSY`, `FULL` or commit errors can falsely report persisted decision IDs/epochs/tombstones. A transaction spanning an actor suspension can interleave unrelated operations.
**Proposed change:** Copy transient bindings appropriately ([SQLite binding contract](https://www.sqlite.org/c3ref/bind_blob.html)); copy column data before advancing/finalizing statements. Serialize connections, prohibit suspension inside transactions, check every result, rollback failures, and use atomic migrations. Protect/delete WAL/SHM/journals along with the database. Test disk-full, interrupted migration, lock loss and crash/reopen durability of request IDs and epoch high-water marks. Retain the dependency-free choice if these checks pass; do not impose a 300-line target.

### A12/T2/T5 — NSE evidence and APNs delivery — should

**Objection:** Accept A12's conditional `simctl` wording and honest local-notification label. However, a visible notification does not establish NSE execution, and TestFlight installation alone supplies no APNs sender. The imported S2 `NotificationService.swift` returns generic content on rejection, whereas §9 describes dropping rejected payloads.
**Consequence:** A generic OS banner can be mistaken for verified push coverage; local simulation cannot validate extension lifecycle, locked keychain access, timeout behavior or replacement races. Unspecified generic fallback can be mistaken for protocol-level suppression.
**Proposed change:** Keep processor vectors separate from real-process tests. Require an NSE-specific invocation marker plus verified output/replay evidence for each pinned runtime; otherwise record unsupported/unverified. Provide an external APNs fixture sender with credentials outside the binary and the correct TestFlight production environment. Specify the native generic-fallback exception to §9, trusted content reconstruction, and no routing from rejected payloads. Test timeout, duplicate/older push and concurrent closure delivery. Apple's [NSE documentation](https://developer.apple.com/documentation/usernotifications/modifying-content-in-newly-delivered-notifications) describes remote notification modification; local notifications are not that path.
**Evidence limit:** `xcodebuild -version` reports Xcode 27.0 (27A266a). `simctl list runtimes` failed here because sandbox access to CoreSimulator was denied; neither iOS 18 availability nor NSE execution was verified. No claim that Xcode 27 makes this impossible.

### T2/A1/A13 — Real share-extension XCUITest — should

**Objection:** Presenting a real `UIActivityViewController` is a plausible route, but does not by itself prove the installed OrchShare extension launched. Its activation rule, item-provider types, installation and system share-sheet automation are prerequisites, absent from T2.
**Consequence:** A test can exercise only an in-app composer or fail to discover the extension, yet be counted as extension coverage. Xcode version and an iOS 18 deployment target do not establish an installed runnable iOS 18 Simulator.
**Proposed change:** Pin and record the actual Xcode/runtime pair. Embed/install OrchShare; provide fixture file/text/URL representations matching its activation rule; select Orch in the system sheet (including More when needed), then assert an extension-authored ready job and subsequent app import. If the containing app cannot expose its own extension on that runtime, use a separate test-only host app. Keep cancellation and interrupted-copy cases. Treat self-host discovery as a hypothesis until this smoke test passes, not an API guarantee; keep the fixture unavailable in Release. [Apple's extension testing guidance](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html) does not prove this exact XCUITest path. The sandbox limitation above prevented executing it here.

### P1/P4/P5/A4/U5/D-3/D-5 — Native protocol exceptions and missing contracts — should

**Objection:** “Real pairing” and “nothing above RelayTransport changes” overstate the current contract. §8.3 step 6.4 still requires platform-passkey registration; hiding Type does not remove that pairing step. §8.3 specifies `/app/pair`, while Claude's proposal uses `/pair`. §6.3 specifies `member_remove` requiring Operate, not a universal `leave` route. The linked `docs/gaps.md` is absent in this checkout.
**Consequence:** A mutually agreeable fake/client can pass selected vectors while omitting a required step, rejecting real links, or inventing server removal for a Decide-only phone. Replacing the transport may require semantic changes above it.
**Proposed change:** Record explicit native exceptions under D45–D49: CryptoKit/SE instead of §1.1's browser primitives, suite 2 only, APNs instead of Web Push, and a deliberate native pairing rule for passkey registration. Specify accepted link paths/aliases without changing the five-field fragment. Version pairing/grant/push/leave adapters as well as host view APIs; distinguish local leave, push unsubscribe and membership removal. Restore the gap register before claiming interoperability. The superseded browser text is not a reason to restore Face ID or WebAuthn to D49 signing.

### D-6/A4/U5/V3 — Signed card identity needs CK delivery — should

**Objection:** Accept the signed card as the name source, but §7.1 puts the name in the CK-encrypted part. A4 supplies a card operation without specifying CK-wrap retrieval. The exact `approved` shape in §8.3 contains no CK field.
**Consequence:** FakeHost can conceal a missing contract by handing the phone plaintext names or CK out of band. A host-controlled `hosted_by` string could suppress the client-hosted warning if treated as authoritative.
**Proposed change:** Define a provisional authenticated fetch for the device's sealed CK and verify delegation, card signature, `sealed_hash` and `ck_commit` before using the name. Do not silently extend `approved`. Require §7.1's marker from `delegation.client_hosted`, with “hosted by (unknown)” when necessary; a nonempty `hosted_by` also adds the warning. Test `card.hosted_marker` and wrong-CK cases.

### U7/U8/A5 — Exact reviewed bytes and uncertain retries — should

**Objection:** Scroll-to-end and a delay do not bind the displayed answer to signed bytes. “No bidi tricks” leaves rejection versus silent rewriting unspecified, and “same decision id” leaves crash persistence and retransmission semantics unspecified.
**Consequence:** A transformed display can conceal a different signed value; a crash after host acceptance can generate a second decision, or a queued retry can sign a newly changed answer without review. §13 binds the complete answer and workspace, not only the visible question text/hash.
**Proposed change:** Render and sign one immutable review value containing the exact question/options, answer and §13 fields; visibly expose or reject unsafe controls rather than silently changing meaning. Recompute the question hash from authoritative fields. Persist the decision ID and immutable submitted value before send, reconcile uncertain outcomes, and distinguish retransmitting an already-confirmed decision from creating a fresh signature after lock/change. Handle `stale_epoch` with a new envelope as §8.5 requires, preserving the logical decision. Add crash-after-acceptance and changed-answer tests.

converge with listed changes
