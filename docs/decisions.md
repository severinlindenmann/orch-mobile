# orch mobile: prototype decisions (M0)

Status: converged 10 Oct 2026 from two independent proposals ([Claude](proposals/claude.md),
[Codex](proposals/codex.md)), then challenged by Codex ([challenge-codex.md](challenge-codex.md): all ten points accepted and folded in). Scope: the simulated prototype (P4 started early,
owner-approved). Where this file and a proposal differ, this file wins. Spec gaps found are in [gaps.md](gaps.md).

## Principles

- **P1. The fake sits at the relay wire.** Demo and tests run the real client stack (protocol v2 suite 2 bytes,
  real P-256 crypto, real pairing, sealing, epochs, push sealing) against an in-process FakeRelay, FakeHost and
  FakePrimary. Swapping in an HTTPS transport later changes nothing above `RelayTransport`. Faking at screen or
  repository level is rejected: pairing, epochs and push would go untested until the real relay exists.
- **P2. The fakes are held to the vectors too.** FakeHost/FakePrimary pass the host-side protocol vectors
  (`host_cases`, `cert_request`, `wk_grants`, member lists, push) so app and fake cannot be wrong together.
- **P3. Demo is a separate realm.** Own storage root, keychain prefix and relay host `relay.demo.invalid`, a
  persistent violet "Demo" marker, real transport never reachable from Demo. Leaving Demo wipes the realm.
  Demo certification is never security evidence. Enforced, not just named (challenge C1): synthetic authority
  keys (FakePrimary `PK`, FakeHost `WSK`/`WXK`) are generated fresh per Demo install/reset, kept only in
  backup-excluded Demo storage and erased on exit; no vector scalars or Python reference in shipped code;
  every shared record, route, job, keychain item and notification id is keyed by `(realm, ws, generation)`;
  FakePrimary is constructible only with Demo-scoped stores and the in-process transport; external origins and
  cross-realm links are rejected before any request; real `PK`/recovery material is never imported into Demo.
  Release-build negative tests cover real-transport reachability, live-key lookup, cert reuse and reset scope.
- **P4. D45–D49 override stale prose.** On the iPhone, D49: the device key signs whenever the phone is unlocked
  (Secure Enclave, `WhenPasscodeSetThisDeviceOnly`, no `.userPresence`). Explicit human confirmation in the
  UI stays: the sign sheet shows the exact text before "Sign and send".
- **P5. No silent workarounds.** Where the spec or protocol has no contract for the phone, the code uses a
  provisional, versioned adapter (`host-api v0`) and the gap goes into `gaps.md`.

## Product

| # | Decision | Rejected |
|---|---|---|
| U1 | **No root tab bar.** Home (NavigationStack) = "Needs you" strip, workspace cards, Drop card; toolbar `+` (add workspace) and gear (Settings). The workspace is the unit of trust (D2), so global Questions/Files tabs are out. | 3 root tabs Home / Needs you / Settings (Codex); TIX 5-tab bar |
| U2 | Workspace detail: segmented Questions / Tickets / Files / Terminal (Terminal only when scopes allow; "Later" placeholder, never a fake shell). Factory epics live in Tickets. At large Dynamic Type the segments collapse into a menu. | fifth Factory tab |
| U3 | Needs you list: cross-workspace, grouped by workspace, oldest first; each row carries the workspace colour rail and name; the sign sheet repeats the workspace. Stale data shows "Last checked …", never a confident count. | |
| U4 | First launch: "Try Demo" (primary) and "Pair a workspace". Pair works against FakeHost in Demo; outside Demo it says the relay isn't connected in this build. | |
| U5 | Pairing is a full-screen flow with one screen per state: parse → connecting → compare with host (SAS) → cert pending ("Open orch on <primary>", countdown) → compare with primary (cert code) → joining → ready. Host and primary codes never coexist; the R1 attack (foreign keys in the challenge) shows a full-screen alarm. Entry: Scan QR (camera, device only), Paste link, Demo invitation. Never read the clipboard unasked. | |
| U6 | Demo shows a labelled **Demo host** panel and a separate **Demo primary** panel, default action Reject; Approve unlocks only after "I compared the codes". | auto-approve in Demo |
| U7 | **Sign sheet** renders and signs **one immutable review value** (question, options, answer and all protocol §13 fields; question hash recomputed from authoritative fields). Unsafe characters (bidi controls, invisibles) are shown visibly or the item is refused, never silently rewritten. Plain-text rendering (TIX safe-text rules, no Markdown/links), full text scrollable, scroll-to-end and a 0.8 s arming delay before "Sign and send". Expandable "Signed details" (ws, question id, content hash). Footnote: "This unlocked iPhone signs with its device key." Content change or lock/background invalidates the staged decision. Nothing signs from notification data or lock-screen actions. | Face ID per signature (contradicts D49) |
| U8 | Decision id and the immutable submitted value are persisted before send. Lost response = "Checking whether your answer was received"; reconcile first, retransmit the same signed decision (new envelope on `stale_epoch`, §8.5) and never re-sign a changed answer without a new review. `already_answered` shows who/when; `question_changed` forces a re-read. Offline: drafts only, never queued signatures. | |
| U9 | Three distinct actions. **Leave** ("Remove from this iPhone"): local wipe first (network-independent), server-side push unsubscribe / membership removal as bounded best effort reported separately; where the phone lacks the scope or keys to deregister, it says "Finish on your Mac". **Device revocation** (PK-signed, received and verified): the device identity is dead, every workspace is wiped, new keys are required to pair again. **Reset this iPhone**: wipes everything including device keys. Missing expected custody (e.g. passcode removed) fails closed and cleans dependent stores and push keys; a temporarily locked key is not treated as lost. Orphan keychain items without a realm index (reinstall) are cleaned on launch. Leaving the last workspace keeps device keys and cert (D-1, provisional). | |
| U10 | Notifications: permission asked after the first successful join. No actions on lock-screen notifications. Tap → reverify, fetch state, then act. Badge = last reconciled unanswered count. `question.closed` replaces the delivered item with "Answered on …". | |
| U11 | Drop: Received / Sending; files, short text notes, URLs (never fetched). Compose: destination first, then attachment, note, expiry (7 days). Prototype limits: 5 attachments, 25 MiB. QuickLook preview only after authenticated decryption. | |

## Visual language: "Orbit, native"

| # | Decision |
|---|---|
| V1 | Brand continuity with the dashboard's Orbit identity (near-black reference, teal actions), translated to iOS idioms: stock List/Form/sheets/SF Symbols, follows system light/dark (dark is the reference design). |
| V2 | System fonts only: SF Pro text styles (Dynamic Type), **expanded width** for workspace names and large titles, SF Mono for codes, ids, hashes and sign-sheet machine text. No bundled fonts. |
| V3 | Tokens as in [proposals/claude.md §2.1](proposals/claude.md) (`OC`/`OF`/`OS`/`OR`/`OM`), with: `brand` teal for actions; `you` magenta for needs-you (TIX continuity); `hosted` orange only for client-hosted; `demo` violet only for Demo; `info` blue only for the primary's cert-code frame. Six workspace hues, never colliding with reserved colours. Destructive actions never use `brand`. |
| V4 | Two signature motifs: a 4 pt **workspace colour rail** on cards and rows, and an inset **attention rail** (`you`) on cards with waiting questions (from Codex). Status always has icon + word, never colour alone. |
| V5 | Motion: snappy 0.25 s, no bounce; Reduce Motion → opacity only; security surfaces (codes, alarm, sign sheet) never animate content. Haptics only on accepted decision, alarm and segment change. |

## Architecture

| # | Decision | Rejected |
|---|---|---|
| A1 | Xcode project generated by **xcodegen** from `project.yml` (generated `.xcodeproj` gitignored). Targets: `Orch` app, `OrchNotify` (NSE, `io.severin.orch.notify`), `OrchShare` (share ext, `io.severin.orch.share`), test bundles. Swift 6 language mode, strict concurrency. | checked-in .xcodeproj, Tuist |
| A2 | One SwiftPM package `OrchKit/` with narrow products: `OrchProtocol` (canonical JSON, suite 2, envelopes, sealing, signed objects), `OrchCustody` (key handles, Secure Enclave / software backends, keychain vault), `OrchStore` (SQLite wrapper, workspace containers, wipe), `OrchPush` (pure push processor + replay table), `OrchClient` (transport, bridge session, pairing coordinator, WorkspaceAPI), `OrchFakeHost` (FakeRelay/Host/Primary, scenarios), `OrchUI` (tokens, shared views). | one monolithic Core product |
| A3 | Extension boundaries: the NSE links only `OrchPush` (+ `OrchProtocol`), never signing, network or FakeHost. The share extension links only staging types and OrchUI pieces, no custody, no WK, no FakeHost. `APPLICATION_EXTENSION_API_ONLY` on shared products; a test audits transitive imports. | |
| A4 | `RelayTransport` (bytes on the wire: challenge/login, pairing post/poll, bridge post/poll, grants, member list, card, push register/unregister, leave, Drop put/list/get) and above it `WorkspaceAPI` (snapshot, decide, newTicket, events) implemented by `BridgeWorkspaceAPI`. Screens see only `WorkspaceAPI`, `DropService`, `PairingCoordinator`. Previews use a static `PreviewWorkspaceAPI`; Demo and tests never do. | |
| A5 | State: `@MainActor @Observable` AppModel and per-screen models; a `WorkspaceSession` actor per workspace (seq window, rid store, epoch, polling). Injected `Clock`, entropy and fault policy; UI tests can run the clock ×60. No TCA/Redux. | |
| A6 | Custody chosen by build target, not a runtime probe: device → Secure Enclave (Demo included, so the TestFlight Demo creates a real SE key); Simulator → CryptoKit software keys with a simulated lock state. Two key pairs (`dk_sig`, `dk_kx`) as the protocol needs; D49's "no key split" means no separate human/transport identity. Never fall back silently to software on a device. | |
| A7 | Storage: **SQLite3 C API behind a small own wrapper**, one store per workspace, no third-party code in the binary. Safety contract (C5): `SQLITE_TRANSIENT` bindings, column data copied before step/finalize, one serialized connection per store, no `await` inside a transaction, every result checked with rollback on failure, atomic migrations, WAL/SHM/journal protected and deleted with the db. Tests: disk full, interrupted migration, crash/reopen durability of request ids, epochs and tombstones. | GRDB (Codex; good, but a large dependency in a security-reviewed binary for little gain), SwiftData |
| A8 | Layout: app container `Library/Application Support/orch/<realm>/index.sqlite` + `ws/<ws>/{ws.sqlite,files/,tmp/}`, `NSFileProtectionComplete`, excluded from backup, handles closed on protected-data loss. **Two App Groups** (C3): `group.io.severin.orch` (app + NSE: replay table and removal generations, `CompleteUntilFirstUserAuthentication`, no labels) and `group.io.severin.orch.share` (app + share ext: targets list, staging outbox, removal generations, `Complete`, excluded from backup, bounded retention; quarantine does not survive a workspace wipe). | one shared App Group (gives the NSE read access to staged plaintext while unlocked) |
| A9 | Keychain groups: `.keys` (app only: device keys, cert, WK epochs, pairing secrets, sessions; `WhenPasscodeSetThisDeviceOnly`) and `.push` (app + NSE: `K_push(ws,epoch)`, pinned `wsk_pub`, workspace name; `AfterFirstUnlockThisDeviceOnly`). The share extension has **no** keychain group. All items non-synchronizable, tagged realm/ws/purpose. | share ext sealing with WK access (Claude) |
| A10 | Share extension stages the plaintext file (Complete protection, atomic ready marker, expiry janitor) and says "Saved. Open orch to send."; the app seals and uploads on activation. Removed destination → quarantine, never redirect. | extension seals itself |
| A11 | **Wipe(ws)** is one ordered, resumable, network-independent routine (C2): (1) durably write the tombstone `(realm, ws, generation)` into the app index **and** both App Groups' coordination files; (2) disable share target and routes, cancel and drain in-app writers; (3) delete keychain items (both groups), plaintext, previews, SQLite sidecars, staged and quarantined jobs, pending and delivered notifications; (4) delete the container; (5) only then best-effort network deregistration (separate status). Extensions check the generation under a file lock before publishing a share job or updating replay state / handing off content. The tombstone outlives the container until cleanup completes and guards against late writers and stale rejoin. Crash tests after every phase plus concurrent NSE/share writers. A notification already handed to the OS can't be recalled atomically; a second cleanup pass runs after wipe. | network-first order |
| A12 | Push: pure `PushProcessor` (from S2 PushCore, without S2's self-test file) used by the NSE and by Demo. Demo: FakeHost produces real sealed push bytes → processor → local notification ("local notification simulation" in diagnostics). The NSE path: processor vectors as a library; real-process tests only count with an NSE-written invocation marker plus verified output/replay evidence per pinned runtime (otherwise recorded "unverified"); real APNs via an external fixture sender (credentials outside the binary, production environment for TestFlight). Rejected payloads produce app-authored generic text and no routing: a documented native exception to protocol §9's "drop". | |
| A13 | Launch arguments (DEBUG/UI-test builds only; rejected in Release): `--demo`, `--scenario <name>`, `--reset-demo`, `--seed`, `--clock-scale`, `--ui-testing`, `--fault <name>`, `--initial-route`. TestFlight exposes a curated Demo control screen instead. | |
| A14 | Dependencies: none at runtime. Build tools pinned: xcodegen. Vectors copied from orch-relay with upstream commit + sha256 recorded. | |
| A15 | **Membership and rotation (P3-D6/D7).** Member lists carry `persons` and a `person_id` per member; the phone parses them strictly and only ever raises its epoch from a verified list (forward jumps allowed). The host publishes a list, every member's grant and optional card-key wraps in **one** `PUT /v2/workspaces/{ws}/membership`: it persists `WK_{e+1}` and the exact sealed body before the first send, resends those bytes (never reseals) while the outcome is open, reconciles a `stale_list` after a lost reply with `GET members`, and discards a refused body together with its uncommitted key. Epochs never skip; there is no rotation-abandon route. Rotation invariants I1–I7 are restated for this in `FakeHostBridge.swift`. I3's "a refused body's key is never activated" holds for the host only: a relay can still serve that WSK-signed grant to a phone, so the phone keeps unconfirmed epochs' grants replaceable. That avoids pinning a refused key seen early but does not prevent a lockout (a relay can serve it in the confirming refresh); the fix is `wk_commit` (gaps). | protocol-v2 §7.2, §19.2, §19.7 |

## Testing and delivery

| # | Decision |
|---|---|
| T1 | T0/T1: `swift test --package-path OrchKit` (protocol vectors, reducers, FakeHost vectors, store, wipe, push processor), no simulator. |
| T2 | App: hosted unit tests (keychain, file protection paths) + XCUITest scenarios driven by launch arguments with stable accessibility ids (`home.workspace.<id>`, `pair.sas`, `pair.certCode`, `sign.confirm`, …). Share extension through a UI-test fixture (DEBUG only) presenting a real `UIActivityViewController` with file/text/URL items matching the activation rule; the test selects orch (via "More" if needed) and asserts an extension-written ready job and its import by the app. If the app cannot expose its own extension on the pinned runtime, a test-only host app is used. Pinned Xcode/runtime pair recorded. Runs locally as the gate; output goes into PRs. |
| T3 | CI (GitHub, pinned macOS/Xcode): `swift test` + app build + hosted unit tests on every PR; XCUITest nightly / by label. No signing secrets in CI. |
| T4 | TestFlight from the laptop with `bin/testflight` (xcodebuild archive, automatic signing with the ASC API key, upload, internal group). The ASC key never goes to CI. Export compliance (owner confirmed 2026-10-11): `ITSAppUsesNonExemptEncryption = false`. All cryptography (P-256, HKDF-SHA256, AES-256-GCM) goes through Apple CryptoKit, i.e. encryption provided by the OS, so Apple requires no documentation. ASC questionnaire: uses encryption yes, "none of the algorithms mentioned above", not on the French store for now. Older builds are marked through `scripts/testflight.sh --set-compliance <version>`. Counter-argument recorded: orch's own protocol could count as non-standard cryptography under the EAR; publishing the protocol spec reduces that risk. Revisit before App Store release (EAR mass-market classification, France). |
| T5 | Simulator custody and lock flags cannot prove D49; real Secure Enclave, passcode removal, locked NSE and real APNs stay on the owner's iPhone checklist. |

## Provisional answers to owner questions (owner may override)

- D-1 Keep device keys and cert after leaving the last workspace; "Reset this iPhone" wipes them.
- D-2 The phone is never the primary device in P4. (PR4 adds the primary's relay client calls, D(p) cert-request
  poll, challenge and PK-signed rejection, for FakePrimary and a later primary phone; the shipped app does not act as one.)
- D-7 (PR4) A pairing ends as "denied" (`pair.denied`) only for a PK-signed `cert_rejection` that the phone verified
  under the link-pinned PK and bound to the request of the challenge it showed. An invalid one is ignored (the
  pairing keeps waiting and expires), one for another request raises the substitution alarm, and one that cannot be
  bound (no challenge shown yet) ends as the host's plain "rejected". Fail closed: the host's word never names the
  primary.
- D-3 The QR always carries the universal link (relay origin included); `orch://` only as compatibility with an
  explicit relay origin, otherwise rejected.
- D-4 No `apns-collapse-id` in the prototype (S2's safer default); replacement via the NSE + delivered-item removal.
- D-5 Type scope (terminal) is out of P4 on the phone.
- D-6 Workspace display name comes from the signed card, opened with the device's sealed `CK` via a provisional
  authenticated fetch (delegation, card signature, `sealed_hash`, `ck_commit` verified); `approved` is not
  silently extended. The client-hosted marker comes from `delegation.client_hosted` ("hosted by (unknown)" when
  no name); a nonempty `hosted_by` also shows it. Bridge-provided names are never trusted for identity.
- Native exceptions to protocol v2 (recorded in gaps.md, to be amended upstream): CryptoKit/Secure Enclave instead
  of browser primitives, suite 2 only, APNs instead of Web Push, no passkey registration in pairing (§8.3 step
  6.4) on the native app, links `/app/pair` canonical with `/pair` accepted as alias, local leave vs push
  unsubscribe vs `member_remove` (Operate) kept distinct. Pairing, grant, push and leave adapters are versioned
  like the host view API.

## Build order (maps to plan steps M1–M9)

1. Skeleton: xcodegen, three targets, OrchKit with empty modules, CI, tokens, Home with preview data.
2. OrchProtocol + vectors (port S1 Support, S2 PushCore, hardened to Swift 6).
3. OrchCustody + OrchStore + wipe, hosted tests.
4. FakeRelay/Host/Primary + pairing coordinator + pairing UI + XCUITests per scenario.
5. Bridge session, host-api v0, Questions/Tickets, sign sheet, decisions.
6. Push: OrchPush, NSE target, Demo local notifications, `simctl` fixtures.
7. Drop basics + share extension + staging outbox.
8. Settings, Leave/revoke, Demo controls polish, `bin/testflight`, first TestFlight build, prototype iPhone checklist.
