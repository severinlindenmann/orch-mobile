# Live mode

Status: adopted design, 14 Oct 2026. PR A (realm boundary and capabilities) is implemented; PR B and PR C are planned below.
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

Ordering on a leave, all synchronous before the first await: the share index is published empty (the extension offers no destination of
the outgoing realm, independent of any view), the view graph is dropped (`epoch`), and the outgoing `RealmLifetime` is invalidated.
Then the wipe runs. While the state is `.leaving` or `.starting` the root shows only the `app.starting` spinner: Home is blank by
design, so no stale handle is reachable from a view. After a successful wipe the target realm is booted once: Welcome, or Demo for
"Reset Demo data" (`thenDemo`), which keeps the device label and ends the transition only after the Demo boot completes. A Demo that
cannot start shows a notice over Welcome. An unfinished wipe at launch blocks every realm, even with `--demo`; recovery comes first.

* `RealmRuntime`: what the app needs from a realm's runtime: coordinator construction, workspace restoration, wipe and shutdown
  (plus clock, presentation gate and draft location). `DemoRuntime` conforms; `LiveRuntime` will.
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

## Before Live (PR B) can ship

PR A is a boundary for Demo; the following are blockers for making Live reachable (Opus review).

1. **Realm generation fence inside OrchClient (H1).** The app-level `RealmLifetime` only guards app code. The Live `RealmContext`,
   custody and transport must check a realm-level generation themselves with `perform()` semantics, as `DemoGeneration` does, so a
   stale handle cannot sign or write after Leave.
2. **Synchronous `RealmRuntime.invalidate()`** is the first statement of teardown. The runtime tracks every pairing coordinator and
   every `WorkspaceSession`, and `shutdown` cancels and awaits them, so a late pairing commit or decision sign cannot survive
   Leave Live.
3. **`retire()` (L1)** must not be used on a realm with live sessions, or must be completed to stop and drain them.
4. **Pending server cleanups (L4)** are cleared only after the wipe succeeds, not at teardown start.
5. **Failed reset retry (N1):** after a failed reset, Retry must remember the destination (Welcome or Demo), including `thenDemo`.
6. Done in PR A, listed for completeness: stale share destinations are retired synchronously at leave.

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
* **PR B, Live vertical slice.** OrchClient public transport factory, `LiveRuntime`, HTTPS pairing and the invitation screens,
  restoration, complete Live wipe and "Leave Live", scene lifecycle in `AppRoot`, `PairingModel` without the Demo-only coordinator.
  Live becomes reachable only together with restoration and a complete wipe.
* **PR C, hardening.** Diagnostics screen, real device round trip, restart and lost-response tests, link-opening decision, documentation updates.
