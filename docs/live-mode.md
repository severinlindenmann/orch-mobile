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
preserving answers still being settled (`pe_reviews` / `pe_attempts`) and ticket submission identities.

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
  answers still being settled (`pe_reviews` / `pe_attempts`, C2b) and ticket-submission identities, which live in that store, are preserved) and builds a `WorkspaceSession` with its original
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
* **Capabilities** (`RealmCapabilities.live`): drop, share, push and demoControls all off until owner-approved relay routes exist. `writes` is ON since C2b increment 4 (answers and new tickets), but the capability is only the first of three conditions: a Live write also needs a Secure Enclave policy (software custody, e.g. the Simulator, has none) and the host's own signal, column-R `whoami.relay` with the op at version 1 and `r6_ready` true (see `host-api-v1.md`, "Live write signal"). The signal is kept in memory by the session, read at `startViews`, on foreground and on an epoch change, and cleared on background, on a failed or malformed read and on an epoch change: no signal, no new Live signature and no first dispatch.
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

* **List `state` is presentational for evidence, authoritative for the cache.** `DropListing.gone` (`expired`, `retired`, unknown or `pruned`)
  comes from an unauthenticated relay field: word it as a report ("Removed (reported by relay)", "Expired"), never as fact, and never stop a
  pending upload from being reconciled by its signed-descriptor read-back. It must never purge pending-upload rows, chain heads or signed
  descriptors. `claimed_by` is a hint as well; a download re-reads the wraps and only a wrap that opens to the committed DEK counts.
* **The local download is a cache, not evidence (decision, 15 Oct).** Stale plaintext of an object the host retired, that expired or that can
  no longer be verified is the riskier failure; losing a cache to a lying relay is an availability nuisance. So after a COMPLETE verified
  list walk (both directions, `listVerifiedRows` returned) `LiveDrop.refresh` calls `purgeLocal(except:)`: the cached plaintext of every
  object that is not shown live (blocked, tombstoned, or absent) goes, object by object (`WorkspaceContainer.purgeDownloads(keeping:)`; the
  live objects' caches are untouched). `verifyVisible` failing for one object purges that object only (`purgeDownloads(objects:)`). An entry
  that did not parse names no object. The only purge-everything paths are the verification alarm (`report`) and Leave workspace / Leave
  Live / Reset (the wipe removes the files directory; verified by `LocalWipe`).
* **Incomplete walk: fail closed on display, purge nothing.** If the walk throws (offline, `tooLarge`, a page error), `LiveDrop.outdated`
  is set: nothing is purged, but cached copies are not shown as current (the row says "May be outdated", no text or preview) and `open` is
  refused until a complete walk succeeds.
* **Stalled uploads.** `DropService.stalledUploads()` lists pending uploads whose object the relay reports gone while the signed expiry has
  not passed ("Removed by the host? Retry or discard"); they are retried at most hourly, `retryUpload` and `discardUpload` resolve them.
  `storageFull` and `retryLater` carry the seconds to wait; `rotationPending` means the host has a rotation due.
* **Purge granularity (done).** Purging is per object. After a complete walk `LiveDrop.refresh` calls `purgeLocal(except:)` with the set
  of objects shown live (`WorkspaceContainer.purgeDownloads(keeping:)`); `verifyVisible` failing for one object calls
  `purgeLocal(objects:)` (`purgeDownloads(objects:)`). The list's `blocked` ids are opaque and name no object, so they drive no purge: a
  blocked object is simply not in the live set. Heads and every live object's cache are untouched.
* **`open` racing a walk.** After the download returns, `open` keeps the file only if the list is not outdated and still shows the object
  live at the version it opened; otherwise that object's file is purged, nothing is shown and the status says "No longer available" (or "List
  may be outdated: refresh first"). A refused `open` while outdated says so in the status.
* **Failed cleanup after a complete walk** is not an incomplete walk: the list is current, so nothing is marked outdated; the status says
  "Local cleanup needs retry" and the next refresh runs the same purge again.

## Relay push wiring notes (P3-D40, protocol-v2 section 19.10)

The phone side is built and stays **capability-off in Live** until `relay.dev.severin.io` serves the push routes. Demo is unchanged: its
push is the local simulation, and Demo never registers.

**The one switch.** `RealmCapabilities.live` in `App/Live/LiveRuntime.swift`: set `push: true`. Nothing else changes. Checked on 15 Oct 2026:
`relay.dev.severin.io` answers `{"detail":"Not Found"}` (FastAPI routing 404, the body of a route that does not exist) for
`POST /v2/push/register`, `/v2/push/unregister` and for an unrelated `/v2/push/...` path alike, and for `/v2/drop/list`. A relay that has D40 but
no push configured answers `404 {"error":"not_found"}`; a relay with push answers 401 `unauthenticated` to the same request without a bearer.
Flip the switch only after the unauthenticated probe says 401, and re-run it first. The phone treats a 404 from a configured route as "push
is off on this relay" (below), so a premature flip degrades to a visible diagnostics line, not an error.

**Registration** (`OrchClient/PushService`, `RelayClient.registerPush/unregisterPush`, device session, `POST /v2/push/register`):
body `{workspace_id, registration_id, env, topic: "io.severin.orch", token}`, `token` b64u of 32..100 bytes. The registration id is 16 random
bytes (hex), kept per (workspace, env) in the workspace store (`push_registrations`, migration 14) and saved BEFORE the request, so a lost
reply retries the same body (200, free). A changed token mints a new id (a new id retires the old one at the relay; the same id with another
body is 409). 409 `registration_conflict`: mint a new id and register once more, a second 409 is reported. 404: `relayPushOff`, nothing is
asked again until the next launch. 403 `not_eligible` / `revoked`: shown, not retried. 429: no retries for `Retry-After` (300 s without one).

**When it runs** (`App/Push/PushRegistrationCoordinator`, owned by `LiveServices`, only when the realm has `capabilities.push`):
* A workspace is ready (joined, or restored at launch): publish the notification extension's material, follow the epoch, read the OS
  permission (never prompts), and register if the permission is allowed and a token is stored.
* iOS hands over the token at every launch that registers (`OrchAppDelegate.onTokenReceived`, every time, changed or not): every Live
  workspace registers again. Same token, same body, no cost at the relay; a new token gets a new registration id.
* **Epoch.** `WorkspaceSession.setEpochObserver` fires when the confirmed epoch rises (a key was installed); the coordinator republishes
  `K_push` (one keychain item per workspace, `PushMaterial`, never `WK`) in the same step. Right after a rotation, before that step,
  pushes show generic text (acceptable, A12).
* **Leave workspace.** The wipe's tombstone is written first (`LocalWipe.begin`: the intent is durable, a relaunch finishes it); only then
  the owed cleanup is recorded (a kill in the window below must not lose it; never before the tombstone, so no owed item exists for a
  workspace that could reopen), then `registration_id: null` (all of this device's registrations in the workspace; allowed without membership) goes out through the realm
  transport and the device key (the workspace session is stopped), bounded to 3 s in total (all in-flight generations share the bound). The
  item is removed only on a definite done (removed, push off, or a 403 `not_eligible`/`revoked`/`not_for_this_device`); an unreadable
  reply (`bad_reply`), a timeout, an error or any unknown outcome stays owed (one classifier, `PushRegistrationCoordinator.removal(for:)`,
  serves both Leave and the retry `LiveRuntime.unregisterPush`; an unknown refusal is therefore retried for up to 60 days).
  An item whose workspace is still listed with its own generation (a Leave in progress, or `removalIncomplete` after a failed wipe) is
  neither sent nor dropped by a retry; one whose workspace is listed with another generation (a re-pair) is dropped unsent. A retry running meanwhile neither sends nor drops that item.
  If the relay cannot be reached, or an in-flight registration outlasts the bound, the cleanup stays in `ServerCleanupStore` (workspace and generation only), shown under "Finish on
  your Mac", and retried by `serverCleanup` (`LiveRuntime.unregisterPush`) at every Live start, every foreground and on "Retry now", before
  any registration (bounded to 3 s for the registration; the retry itself continues in the background and never drops an item on a timeout). An owed item for a workspace that is joined again (a re-pair is a new membership) is dropped unsent, and one older than 60
  days is dropped (the relay deletes unrefreshed registrations by then).
* **Leave Live / Reset.** In this order: (1) synchronously, the Live reset gate is persisted, the controller is `.leaving`, the push
  coordinator refuses every register and publish (`closing`), every workspace is `removing` (shown as such, never presented) and background
  reconcile tasks are cancelled, all before any await; (2) the sessions are stopped and the registrations of all workspaces removed at
  once through the realm transport and device key, under ONE 3 s deadline for the whole step (when it passes, step 3 proceeds regardless); (3) the realm is invalidated and
  wiped. A kill in step 1 or 2 is finished at relaunch, which finds the gate, skips the relay and completes the wipe. The device key goes
  with the wipe, so nothing can be owed afterwards: if the relay was unreachable the registration ends by the host's removal of the device
  from the member list, an APNs 410 / `BadDeviceToken`, the device's revocation, or 60 days without a refresh. A second tap with another
  intent while this runs is refused with a visible notice.
* **Refusals.** 403 `not_eligible` / `revoked`, 400 `malformed` and an unusable reply are permanent: that workspace is not asked again in
  this process (a re-pair starts fresh). 429 backs off, 404 stops everything until the next launch.
* **Stale environment.** A registration made under one APNs environment (for example a development build later replaced by TestFlight) is not
  removed by the phone; it ends when APNs rejects its token (`BadDeviceToken` deletes it at the relay) or after 60 days. The stored token is
  used only if it was issued for the environment the build resolves now.

**APNs environment** comes from how the build is signed (`PushEnvironment.resolve`, resolved once per process), not from the build configuration: the
`aps-environment` of `embedded.mobileprovision` (`development` is `sandbox`, `production` is `production`); no profile on a device (TestFlight,
App Store) is `production`; a profile file that exists but cannot be read or parsed, the Simulator and a profile without the entitlement have none and never register or call the relay.

**Notification extension.** It reads `userInfo["o"]` as a JSON string only (`RelayPushBody.outer`), then the section 9 sealed outer with its
3 072-byte cap; the relay's alert text (`orch` / `New activity in orch`, at most 3 175 bytes in all) is the extension's own generic text and is
never read. There is no collapse id: a `question.closed` push replaces the delivered question through the entity key (`orch_key`), exactly as
before, and the app's reconciler does the same when it opens. Open for the first device test: the extension adds the sound, the relay sends
none (inferred, not verified).

## Enable checklist: Drop and push in Live (both capabilities are OFF today)

Flip `RealmCapabilities.live` in `App/Live/LiveRuntime.swift` (`drop: true`, `push: true`) only when ALL of these hold.

1. **Relay routes deployed on relay.dev.** Verify with an unauthenticated probe, no VPS actions, respecting the relay's ~60/min throttle (a
   handful of requests, a couple of seconds apart): `POST https://relay.dev.severin.io/v2/push/register`, `/v2/push/unregister` and
   `/v2/drop/list` with body `{}` and no bearer must answer **401** (`unauthenticated`), not **404** (`{"detail":"Not Found"}` is the FastAPI
   routing 404 of a route that does not exist; `{"error":"not_found"}` is push not configured). Result on 15 Oct 2026 (after #77 merged):
   all three still 404, so neither capability may be enabled yet.
2. **Readiness items done** (this PR): Drop per-object cache purge with the cache policy above (blocked, tombstoned and absent purge only
   their own cache after a complete walk; an incomplete walk purges nothing and disables open); push follow-ups #78 (L-a to L-e: owed
   cleanup durable after the tombstone and before the window, one global drain bound that never skips teardown, bounded owed-cleanup retry
   that never drops on timeout, unreadable unregister reply stays owed, reconcile cancelled in `beginLeave`).
3. **Device test for the notification extension's sound is still pending** (the relay sends none; the extension adds it; inferred, not
   verified). Do it on a real device with a TestFlight or development build before relying on push.
4. After flipping: run the simulator suites, `scripts/check-release-flags.sh`, and re-run the probe once more.
5. **Do not flip `push` off while registrations exist.** With the capability off there is no coordinator, so Leave owes nothing and the
   relay keeps the device's registrations until a host removal, an APNs 410 or 60 days without a refresh.

## The Simulator dev-sandbox lane (C2b increment 5, host 11A.17)

A Simulator can answer questions in a throwaway **dev sandbox** with its software key, signed `auth: "convenience"` (no presence check). It is a
separate app, `OrchDevSandbox`, and answers only (a `ticket.created` is never admitted on the dev gate; test creation on a device).

- **Where it exists.** OrchKit compiles the lane only under `DEBUG && targetEnvironment(simulator)` (`DevSandboxLane.swift`, `PersonEventPolicy.Lane.devSandbox`,
  `PhoneActor(.convenience)`, the permit's lane workspace, the transport check). A device build (any configuration) and a Release Simulator build contain none of
  it; `scripts/check-dev-sandbox-symbols.sh` checks that with `nm`/`strings` in CI. The normal Debug Simulator `Orch` has the OrchKit code but no way to turn it
  on: the switch is a `DevSandboxLaneEnabler`, minted only by App code under `ORCH_DEV_SANDBOX`, which only the `OrchDevSandbox` target defines.
- **The variant.** XcodeGen target and scheme `OrchDevSandbox` (iphonesimulator only, Debug only, bundle `io.severin.orch.devsandbox`, its own entitlements and
  keychain group base `io.severin.orch.devsandbox` through the `OrchKeychainGroupBase` Info key, App Groups `group.io.severin.orch.devsandbox[.share]`, no
  extensions, no push, no `orch://` link). Pair through the in-app scanner or paste. Never pair it into a real workspace (owner note 4): after the join the
  first `whoami` must carry `relay.dev`, else the workspace screen says "Not a dev sandbox. Remove this Simulator on your Mac." and offers Leave.
- **Signal.** `whoami.relay.dev = {sim_convenience:true, sandbox:"<id8>"}`, present only while the host's dev gate passes for that workspace
  (`HostWriteSupport.dev`, parsed leniently: anything else is nil and the lane stays off; the rest of the read is untouched).
- **Policy.** `PersonEventPolicy.derive` gives `auth: .convenience, lane: .devSandbox` only for a Live context + software custody + the enabler + a reader
  capability of level 1 + the variant's origin: `https://relay.dev.severin.io`, or (variant only) a loopback `http://127.0.0.1:<port>` / `http://[::1]:<port>`
  relay so `dev-pair --relay local` works in the automated e2e. A Secure Enclave identity is always `secure-enclave-unlocked`; Demo is unchanged. The variant's
  context (`RealmContext.liveDevSandbox`) refuses every other origin. A loopback relay is reachable only from the Mac the Simulator runs on; the host's dev gate and
  sandbox proof stay the real checks.
- **Freshness (O6).** `freshDevGrant()` is one `whoami` call, made for every `reviewQuestion` of an open question and before every automatic re-sign; it returns a
  grant only if that same reply says `relay.dev.sim_convenience`, `ops.answer == 1` and `r6_ready`. Without one: no sheet ("This host does not accept
  Simulator answers"), nothing signed, no re-sign (the answer goes back to review). `answer` signs only a review that carries the grant; the write gate's first
  dispatch needs a convenience attempt on the lane and does not read again. A resend or a settlement read is never blocked. A host `op.not_allowed` (it restarted
  without the flag) is class D: shown, never re-signed.
- **Transport.** `WritePermit` carries `.devSandbox(workspace)`; `RoutedRelayTransport.bridgePost` lets a `convenience` permit over the network only for exactly
  that workspace's route, on a variant origin, in a Live context. The in-process Demo sender refuses it.
- **UI.** A red banner "DEV SANDBOX: convenience signing · <id8>" on the workspace screens and the sign sheet; the sign-sheet footnote and the refusal text are
  fixed strings (`ConvenienceBanner.swift`).
- **Tests.** OrchKit `DevSandboxLaneTests` (derive matrix, `relay.dev` parse, transport, session flows against the FakeHost with a Live-realm rig) run on the
  Simulator destination (`xcodebuild test -scheme OrchKit-Package ... -only-testing:OrchFakeHostTests/DevSandboxLaneTests`), not macOS `swift test`. The variant's
  own unit tests are `OrchDevSandboxTests`; `LaneAbsenceTests` runs in `Orch` under Release (`scripts/check-release-flags.sh`).
