# Live mode

Status: adopted design, 14 Oct 2026. PR A (realm boundary and capabilities), PR B1 (realm generation fence) and PR B2a (`LiveRuntime`, restore, realm-wide wipe; no user-facing Live entry) and PR B2b (Live entry and Live pairing UI, below) are implemented; PR C is planned below.
Origin: a Codex design proposal, edited to the owner's decisions.

## Decisions

1. **One active realm at a time.** Demo and Live both stay available in TestFlight through ordinary UI, but only one realm exists on
   the iPhone at once. Switching is explicit and destructive: it deletes the current realm's local data and requires pairing again.
2. **Explicit destructive switch.** Settings offers "Leave Demo and pair your Mac" or "Leave Live and try Demo". The confirmation says
   the current realm's local data is deleted. A Live link opened during Demo never switches silently; it is held in memory while the
   user chooses.
3. **The origin comes only from the invitation.** There is no relay URL field. One relay origin and one owner per Live installation
   initially; an invitation for a different origin is rejected before any network access, and an existing graph is never retargeted.
4. **Drop, push and share are hidden in Live** until owner-approved contracts exist. They are capabilities, not `!isDemo` checks.

## Realm model

`AppRoot` owns a `RealmController` with the states welcome, starting, demo, live, leaving and recoveryRequired. A transition replaces
the whole realm's service graph (a new `LiveServices`) and view graph (the root view is keyed on the controller's `epoch`), so
navigation stacks, sheets and pairing presentations of the outgoing realm go with it.

Ordering on a leave, all synchronous before the first await: the outgoing realm's share destinations are tombstoned (journal, coordination record,
staged and quarantined plaintext purged) and the index republished without them, the view graph is dropped (`epoch`), and the outgoing `RealmLifetime` is invalidated.
Then the wipe runs. While the state is `.leaving` or `.starting` the root shows only the `app.starting` spinner: Home is blank by
design, so no stale handle is reachable from a view. After a successful wipe the target realm is booted once: Welcome, or Demo for
"Reset Demo data" (`thenDemo`), which keeps the device label and ends the transition only after the Demo boot completes. A Demo that
cannot start shows a notice over Welcome. An unfinished wipe at launch blocks every realm, even with `--demo`; recovery comes first.

* `RealmRuntime`: what the app needs from a realm's runtime: coordinator construction, workspace restoration, wipe and shutdown
  (plus clock, presentation gate and draft location). `DemoRuntime` and `LiveRuntime` conform.
* `DemoControls`: everything Demo-only (scenario, fake host and primary, faults and lock simulation, notification simulation, Drop
  fixture seeding). Only `DemoRuntime` conforms; non-Demo code reaches it through `LiveServices.demo`.
* Realm and capabilities are tied to the attached runtime: a graph with no runtime (Welcome, recovery) has no realm and no
  capabilities (no push registration, no share, no Drop). `isDemo` is derived from the runtime's realm, and `ShareWorld` takes its
  realm from the graph.
* `RealmCapabilities` on `AppServices`: `drop`, `share`, `push`, `demoControls`. Demo has all on. Gated: Drop tab, card, routes and the
  workspace Files segment (stale routes show "Not available"); share extension destinations and import work; APNs registration and the
  permission prompt themselves; Demo controls and `SimulationNotice`. `LiveDrop` is not constructed when `drop` is off.
* `RealmLifetime`: invalidated at the start of a transition. Pairing, review/decision and reconcile completions check it before they
  write, sign or register, so late completions after leave are inert. It sits beside the existing per-workspace generations.
* Cleanup state is per realm (`ServerCleanupStore(realm:)`); the pre-realm list is adopted as the Demo list once.

## Entering, leaving, resetting

* **Remove workspace**: the existing local-first wipe; realm identity is retained after the last workspace.
* **Leave Live**: wipes every Live workspace, pending pairing, certificate, device keys and other Live data; returns to Welcome.
* **Reset this iPhone**: wipes both realms and their recovery state.
* Backgrounding or terminating the app is not leaving Live; Live restores on relaunch.
* A failed wipe shows "Removal incomplete / Retry" (`recoveryRequired`) and the destination realm is not activated meanwhile.
* Leave results never claim server-side success that was not acknowledged. Default text: "Removed locally; finish removing this
  device on your Mac."

## Live entry (PR B)

| Screen | Content |
|---|---|
| Invitation | Scan QR or explicitly paste a pairing link; instructions point to Remote, then Pair phone, on the Mac. No relay URL field. |
| Review invitation | Parse locally with `PairingLink.parse`; show the origin read-only (ASCII/punycode) and "Connect". Do not present an unverified workspace name as trusted identity. |
| Pairing | `PairingCoordinator` states: connecting, host comparison, primary wait/comparison when required, joining. Host and primary comparisons stay separate even on the same Mac. The phone never acquires primary authority. |
| Ready | Verified `JoinedWorkspace.name` and granted scopes; "Updates arrive while orch is open." |
| Live Home | Real workspace cards, Questions and Tickets, connection state and last-checked time. Never fixture content. |

`LiveRuntime` builds a `.live` `StoreLayout`, `WorkspaceIndex`, protected containers and realm-scoped vault access (separate realm paths
in both App Groups); `KeychainBackend` and `DefaultCustody` (Secure Enclave on device, software on Simulator; a missing keychain
configuration fails closed, no in-memory fallback); `RealmContext.live(origin:pinnedOwner:)`, `URLSessionRequestSender` and
`RoutedRelayTransport` behind an OrchClient public factory (fixed HTTPS origin, redirect refusal, bounded responses, ephemeral
session); `PairingConfig` with real clocks and `SystemEntropy`. Restoration is required: boot resumes interrupted wipes, runs pairing
recovery, loads committed `WorkspaceProfile`s and rebuilds sessions with their generations, pinned keys and durable stores,
preserving uncertain decisions and ticket submission identities.

Scene and protected-data lifecycle ownership moves to `AppRoot`: both workspace and pairing polling suspend in background, reviews
are invalidated and comparison codes hidden; resume verifies and keeps the original deadlines.

## PR B2a: `LiveRuntime` (no Live entry yet)

Implemented, reachable only through a persisted Live install record (`LiveInstall`: the one origin and, after the first pairing, the pinned
owner key, in `UserDefaults` key `orch.live.install`). Nothing writes that record yet (B2b), so no user can enter Live; tests write it.

* **One context, created synchronously.** `LiveRuntime.init` builds the single `RealmContext.live(origin:pinnedOwner:)`, the transport
  (`LiveTransport.make(context:)`, public in OrchClient: `NWRequestSender` behind `RoutedRelayTransport`; `testingTransport(context:sender:)` is
  public but `#if DEBUG` only and `scripts/check-no-test-hooks.sh` fails a shipped target that names it), the vaults and custody. `LiveServices.startLive`
  attaches the runtime BEFORE its boot task starts, so `teardown` can invalidate a boot in progress (M3).
* **Boot does not wipe.** `boot()`: open the Live `WorkspaceIndex` bound to the context's fence at construction, resume interrupted
  per-workspace wipes, run pairing recovery, then `WorkspaceRestoration.restore` (OrchClient): for each committed workspace it re-verifies the
  stored card against the pinned owner key, checks the profile origin equals the install's origin, opens the workspace's own container (so
  uncertain decisions and ticket-submission identities, which live in that store, are preserved) and builds a `WorkspaceSession` with its original
  generation and `WSK` pin on the runtime's single context and transport. A workspace whose record fails verification is skipped (kept, not
  erased); a locked or missing device identity fails the boot (retried when the app is foregrounded), nothing is created. Missing keychain
  configuration: no runtime, `liveBootError`, Live data untouched (no in-memory fallback).
* **Leave Live / Reset.** `teardown` invalidates the context (synchronous), sets the persisted `orch.live.resetPending` gate, awaits any boot,
  then `LiveRuntime.shutdown()`: `shutdownParticipants`, then `RealmWipe` (OrchClient) over UNFENCED vaults: every indexed workspace through
  `LocalWipe`, device keys, `wipe(realm: .live)` on both vault groups (so staged items of an invalidated join, which no index row names, go), the
  index is closed and the realm directory removed, and the Live subdirectories of both App Groups (push state, share staging, quarantine) are
  deleted. Only after success are the gate, the install record and the realm's pending server cleanups cleared. A launch that finds the
  gate completes the wipe before any realm starts. Tombstone coordination files are kept; `WorkspaceIndex.nextGeneration` now also looks at them
  so a rejoin after Leave starts above a burnt generation.
* **Capabilities** (`RealmCapabilities.live`): drop, share, push and demoControls all off until owner-approved relay routes exist.
* Live `leave(workspaceID:)` never reports server success (`finishOnMac`): no acknowledged server operation exists yet.
* Custody: Secure Enclave on device, software on Simulator. Passphrase custody (orch-core #465) is a later item.
* Known limit: restored sessions use the same poll cadence as a fresh join (no long poll yet); real-relay tuning belongs with PR C.

## Before Live (PR B) can ship

PR A is a boundary for Demo; the following are blockers for making Live reachable (Opus review). Status after B2a is marked per item.

1. **Done (PR B1): realm generation fence inside OrchClient (H1).** Every `RealmContext`, Demo and Live, owns a `RealmGeneration`
   (`DemoGeneration` is an alias). Its `perform {}` is a recursive lock held only across synchronous check-and-act bodies; `invalidate()`
   takes the same lock, so nothing that passed the check is running when it returns and nothing starts later. Enforced once per resource:
   custody leases (`LeasedSigner`/`LeasedKeyAgreer`, also re-leased by `WorkspaceSession.init`), transport send (check immediately before
   `sender.send`; an await cannot be held under the lock), the workspace store (`SQLiteDatabase` writes and transactions, BEGIN..COMMIT
   inside the fence, bound to the container by `WorkspaceSession.init`), the pairing index (the fence is bound to the `WorkspaceIndex`
   itself: `addWorkspace`, `savePairing`, `commitJoin` apply it, wipe-type writes never do), and the vault views handed to sessions and
   coordinators (`put`, `delete` and `wipe` are fenced, because a successor realm reuses the same ids). Only the reset/teardown path
   holds unfenced views, so the wipe still works. `SQLiteDatabase.query` is read-only (SELECT/WITH only; the authorizer denies transaction
   control, ATTACH/DETACH, ANALYZE, and PRAGMA except a read-only allowlist: table_info, table_xinfo, index_list, index_info,
   index_xinfo, journal_mode, page_count, page_size, user_version, schema_version, foreign_key_list, foreign_key_check,
   integrity_check, quick_check, freelist_count).
   Rule: at most one externally visible effect per fenced body, placed last (a body that signs and then writes is one critical section;
   a body that wrote and then sent could not be undone).
2. **Done (PR B1): synchronous `RealmRuntime.invalidate()`** is called by `LiveServices.teardown` (after the `retired` guard, before any
   await). Sessions and pairing coordinators register with the realm generation (weakly; `DropService` is not a participant), and
   `RealmContext.shutdownParticipants` cancels them concurrently in unstructured tasks and returns on "all finished" or the deadline
   (default 5 s), never awaiting one that ignores cancellation; `DemoRuntime.reset` calls it before the wipe. A future `LiveRuntime` must
   do the same in `shutdown`. Rule: a runtime owns exactly one `RealmContext`; `WorkspaceSession.init` requires its transport and context
   to share one generation, and a `WorkspaceIndex` or container accepts one fence only. Known limit: a signature or SQLite transaction in
   flight holds the gate, so `invalidate()` can wait that long (a Touch ID prompt must not run inside `perform`; phase 3).
   - **Done (B2a): the B2 note.** `LiveRuntime` must close its index (and containers) the way `DemoSetup.reset` does, and bind the index to the
     context's generation at construction. The Live reset must call `wipe(realm: .live)` on unfenced vaults, not only the per-workspace
     wipes driven by the index, because an invalidated join's staged items are not in the index. It must also use the same
     `resetPending` boot gating, so a Live successor never starts before that wipe succeeds. `SecretID`s are not generation-tagged.
   - **Done (B2a): M3.** A boot in progress must be invalidated at teardown. Create the realm context synchronously and make it reachable
     (for example on the controller) before the boot task starts, so `teardown` can invalidate it before the runtime exists.
   - **Done (B2a): L6.** Push material has a fenced path: `VaultPushSink(vault:)` wraps a fenced `RealmVault` and `LiveRuntime.makePushSink()` exists (nothing calls it while push is off; the unfenced backend initializer is DEBUG-only), the ticket draft is written inside `RealmRuntime.writeFence` (a Live workspace without a fence cannot save one), and a Live `ShareBridge` exists only with the share capability and a fence (it runs its App Group writes inside it). Original text: Live writes outside OrchClient (push material `VaultPushSink`, share staging, the draft file) must go through
     the runtime's fence. Consider making the fence a required init parameter for Live-layout stores.
3. **Done (B2a): `retire()` (L1).** It now drains: the realm is invalidated, then `RealmRuntime.drain()` and the workspace consumers are awaited in `retireDrain` (`waitForRetire`). Original text: **`retire()`** must not be used on a realm with live sessions, or must be completed to stop and drain them.
4. **Done (B2a): pending server cleanups (L4)** are cleared only after the wipe succeeds, not at teardown start.
5. **Done (B2a): failed reset retry (N1):** after a failed reset, Retry must remember the destination (Welcome or Demo), including `thenDemo`.
6. Done in PR A, listed for completeness: the outgoing realm's share destinations are retired by tombstoning at leave (the share fence).
7. **Runtime-less share realm (L-a).** A graph with no runtime has no share realm: `shareRealm` is nil and no `ShareBridge` is created for it. Keep it that way when Live is added.
   Done in PR A as well: `ShareBridge` captures its realm once and `publishTargets`, `refresh` and the claim are no-ops when
   `world.shareRealm` differs, so a stale refresh during teardown cannot act as "live".
8. The share fence is fail-safe: if the journal write or replay fails, the index keeps its entries and is marked stale, and the next
   boot completes the removal.

9. **Done (B2a): a no-realm boot does not retire Live destinations** (`completeShareRemovals` retires only Demo's). Original text: **A no-realm boot must not retire Live destinations.** Today `completeShareRemovals()` retires every persisted entry when the boot ends with no realm. That is safe while only Demo exists, because Demo is wiped at every boot anyway. Once Live exists, a failed or absent runtime (a boot error, `resetIncomplete`, a Live restore that fails offline or before first unlock) must not tombstone `"live"` destinations, because that burns their generation for good. A no-realm boot retires only realms whose storage is wiped at boot (Demo). Live destinations are retired only by an explicit Leave Live or Reset.

## Live entry (PR B2b, implemented)

Owner decisions (15 Oct 2026): one relay origin and one owner per Live install; invitations by QR or paste only (no universal links yet);
the QR carries `orch://pair?relay=<origin>#v2.…` (decisions D-3, amended); an `orch://` open always lands on a review screen; no http
loopback in the app; Drop, push and share stay off in Live; the Simulator uses software custody for now.

* **Welcome** offers "Try Demo" and "Pair your Mac" ("Connect to orch on your Mac. Your Mac approves this iPhone.").
* **Intake (`LiveIntake`, owned by `AppRoot`, presented above the realm's view graph).** Scanner, paste and `onOpenURL` (cold launch included:
  held until the realm booted) all end in one function that parses with `PairingLink.parse` and classifies BEFORE any network access:
  `review` (Welcome, or Live with the same origin), `switchOffer` (Demo active: the link is held in memory; "Leave Demo and pair your Mac"
  with a destructive confirmation, then the REVIEW of the held link, never an automatic connect), `refused` (not `https`, a Demo origin,
  another origin than the existing install's, an unfinished transition or wipe). The review shows the origin read-only (ASCII/punycode) and
  "Connect"; Connect is the first moment anything is written or sent.
* **Scanner.** VisionKit `DataScannerViewController` (iOS 18: every supported device has it; AVFoundation is not needed as a fallback). The
  Simulator or a denied camera shows why scanning is unavailable and offers "Paste link instead" (`ScannerAvailability`).
  `NSCameraUsageDescription` and `CFBundleURLTypes` (`orch`) come from `project.yml`.
* **Live pairing.** `LivePairingModel(services:link:)` runs the coordinator from `LiveRuntime.makeCoordinator()` through the existing
  `PairingScreen` states (connecting, host comparison, primary wait/comparison, joining, ready). Ready shows the verified workspace name,
  the granted scopes and "Updates arrive while orch is open." A pairing ended by its realm (`staleGeneration`) is a cancel.
* **Entry ordering (`LiveServices.liveRuntimeForPairing`).** (1) the origin must be an `https` Live origin and no other realm or unfinished
  wipe may be active; (2) orphans are wiped first: `RealmWipe.run(index: nil)` = `wipe(realm: .live)` on both vault groups,
  `custody.delete(realm: .live)` and the Live files (the keychain survives an uninstall, a keychain that cannot be read stops the entry
  here); (3) the install record is persisted with a THROWING `LiveInstallStore.save` (it must read back), a failure fails the flow with
  nothing left behind; (4) only then the runtime is created and booted. So no Live keychain item or index row exists without an install record.
* **Owner pin: derive at boot.** The record is written before the first pairing without an owner. `LiveRuntime.boot` derives the pin from the
  committed profiles (`agreedOwner`): none committed, nothing to record; one owner, recorded with a throwing save (a failed write shows a
  notice and is retried at the next launch; the join is not undone); more than one owner, the boot is refused (`ownerDisagreement`, nothing
  rebuilt, nothing erased, Leave Live is the way out). With a pin recorded, a profile of another owner is not rebuilt (skipped, reason
  `owner`) and shown in Live Home. The first join also records the pin right after it (best effort); the boot derivation is the durable
  guarantee, so a crash between `commitJoin` and the record write is repaired at the next launch. The coordinator's stored device
  certificate refuses a second owner meanwhile.
* **Review-fix round (PR #72).** The review screen shows the invitation source and a warning and never says "your Mac" for the unverified
  host; a second invitation never swaps the reviewed origin (visible banner); the paste field is privacy-sensitive, hidden when the scene is
  inactive and cleared after use (the clipboard too when it came from the paste button); `recordOwner` is inert after a Leave; the scanner
  asks for camera permission before showing "camera off" (device pass needed, the Simulator has no camera); `ownerDisagreement` has its own
  copy ("two different owners ... Leave Live to start over"); the Leave notice mentions the Mac only after a join; a failed force-erase boots a
  fresh graph so "Try again" works.
* **Install record location (Opus L3): not moved to the `.keys` keychain group, on purpose.** It is read synchronously in many places and
  by per-launch preference suites in UI tests, and a keychain-resident record would SURVIVE an uninstall while the app's data does not,
  leaving a Live install with no index that pins a stale origin forever. `UserDefaults` goes away with the app, and keychain leftovers are
  handled by the orphan wipe above. The epoch rollback binding is not implemented (a restored backup of the preferences could roll the
  pin back to nil; the boot derivation then re-pins from the profiles).
* **Live Home** never shows Welcome once an install exists: real workspace cards, Questions and Tickets, last checked, "Updates arrive while
  orch is open.", and "N workspaces couldn't be verified. Leave and pair again" for restore skips (`LiveRuntime.skipped`). A Live with no
  workspace (cancelled pairing, failed start) shows the way to pair again, the reason it is not running and Settings.
* **Settings.** Realm section (Live: read-only origin, custody, connection and last check, build; no secrets or tokens), "Leave Live" and
  "Leave Live and try Demo" (confirmation), "Leave Demo and pair your Mac" in Demo. A Live leave ends on Welcome with "Removed from this
  iPhone; finish removing it on your Mac." (never a server-side claim).
* **Stuck-wipe escape.** The recovery card of an unfinished wipe offers "Erase Live data on this iPhone" (confirmation): it removes the Live
  files without the keychain or the index (`LiveServices.forceEraseLive`), clears the gate and the record and goes to Welcome. Keychain
  items that could not be reached are removed by the orphan wipe at the next Live entry.
* **`startLive` refuses a retired graph** (`guard !retired`, Opus L1 of #71).
* **Scene lifecycle.** `AppRoot` owns the scene phase: workspaces pause (existing `setActive`) and the Live pairing on screen cancels its
  polling and hides comparison codes (`obscured`); on return the state is re-read and polling resumes with the coordinator's original
  deadlines. Not done: re-verification beyond that re-read, hiding Live Home content while the device is locked (protected data), and
  the share/push parts (capabilities are off).

Tests: `AppTests/LiveRuntimeTests.swift` (install ordering and crash windows, save failure, origin refusal with a request counter, owner pin
derive/disagreement/mismatch, force erase, intake classification incl. Demo hold and cold launch, controller transitions, pairing pause) and
`UITests/LiveEntryTests.swift` (paste, review, Connect, pairing screen, different origin, scanner unavailable, orch:// at launch, Demo switch,
Leave Live). **Not covered, by design of the fakes:** a Live join to `ready` against FakeHost. FakeHost and FakePrimary sign with Demo authorities
and a live realm refuses those by design (`crossRealmCertificate`), so the UI tests stop at "Connecting" behind a relay that never answers
(`--live-test-relay`, DEBUG, `LiveTransport.unreachableForUITests`, covered by `scripts/check-no-test-hooks.sh`). The `ready` and Live Home with a
real workspace are covered by restore tests; the end-to-end join needs a real relay and Mac (PR C).

## Before Live entry (B2b) can ship: status

Findings of the B2a review that belong to the entry flow. All done in B2b except where noted.

1. **Done.** Owner pin (Opus M1): derived at boot from committed profiles with refusal on disagreement, plus an early write after the first join.
2. **Done.** Install before secrets (Opus M2): orphan wipe, then the record, then the runtime.
3. **Done.** `LiveInstallStore.save` throws and fails the join (Sonnet LOW 7).
4. **Done.** Skipped workspaces (Opus L2) are shown in Live Home.
5. **Documented, not done.** Install record location (Opus L3): stays in `UserDefaults` (reasons above); epoch binding open.
6. **Done (minimum).** Stuck-wipe escape (Opus L4): "Erase Live data on this iPhone" from the recovery card.
7. **Open.** Fence by construction (Opus L6): make a Live `RealmVault` carry a non-optional fence.
8. **Known limit (Sonnet LOW 10).** A Live install whose keychain is unavailable cannot be left through the normal wipe (it fails closed); it shows
   as a failed start, and the escape in 6 removes the files meanwhile.

## Priorities and risks

* P0, teardown and restoration: stale handles, interrupted wipes and restart recovery. Test delayed join completion during exit,
  failed wipe then relaunch, and same-workspace rejoin.
* P0, truthful cleanup: Live never reports remote success without an implemented, acknowledged operation.
* P0, integration evidence: a real Mac, relay and device round trip, restart recovery and lost-response reconciliation. Fakes alone do
  not establish interoperability.
* Open owner decisions: supported link domains (QR and paste work with any supported HTTPS origin; universal links need
  associated-domain provisioning); documentation updates for U4/U10 and U1's "no tabs" versus the tabbed Home.

## Plan

* **PR A, realm boundary and capabilities (this PR).** `RealmController`, `RealmRuntime`, `DemoControls`, capabilities, realm lifetime
  fence, realm-scoped cleanup, tests. Demo unchanged; Live is not reachable (no Live entry on Welcome, no Live networking).
* **PR B1 (done), PR B2a (done):** fence inside OrchClient; transport factory, `LiveRuntime`, restoration, complete Live wipe and its gate,
  the Before-Live blockers above.
* **PR B2b, Live entry (done).** Welcome entry, `orch://` and `onOpenURL` into the review screen, paste, in-app scanner, Live pairing UI, install record
  ordering, owner pin, Settings (realm, Leave Live, switching), minimum scene lifecycle (above).
* **PR C, hardening (open).** `reader_decl` pair meta v2 (H12d); passphrase custody for the Simulator (orch-core #465); host-api v1 on the core
  operations; real relay end to end (a Live join to ready, restart and lost-response tests, a real device round trip); fence by construction
  for the Live `RealmVault` (L6); install record epoch binding; protected-data handling of Live Home; diagnostics screen; link-opening decision
  (universal links); documentation updates.

## Drop wiring notes (relay alignment, `DropService`)

Drop stays capability-off in Live until the relay serves the routes. When it is wired:

* **List `state` is presentational.** `DropListing.gone` (`expired`, `retired`, unknown or `pruned`) comes from an unauthenticated relay
  field. Use it only to hide or grey an item and to stop offering open/download; word it as a report ("Removed (reported by relay)",
  "Expired"), not as fact. It must never purge local plaintext, rows or chain heads, and never stops a pending upload from being reconciled
  by its signed-descriptor read-back. `claimed_by` is a hint as well; a download re-reads the wraps and only a wrap that opens to the
  committed DEK counts.
* **Stalled uploads.** `DropService.stalledUploads()` lists pending uploads whose object the relay reports gone while the signed expiry has
  not passed ("Removed by the host? Retry or discard"); they are retried at most hourly, `retryUpload` and `discardUpload` resolve them.
  `storageFull` and `retryLater` carry the seconds to wait; `rotationPending` means the host has a rotation due.
* **Purge granularity (open).** `LiveDrop` calls `purgeExpiredDownloads(nowMs: .max)` (all local downloads) when ANY list entry is blocked
  (`LiveDrop.swift` around the blocked handling and `purge()` with `alarm`). That should become per entry (the blocked object's own file
  only); it needs a per-object purge in `WorkspaceContainer` and is left for the wiring change.
