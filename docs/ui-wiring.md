# Slice 3 → App wiring

App remains unchanged in Slice 3. Keep its models on MainActor; supply one
BridgeWorkspaceAPI per joined `(realm, workspace, generation)`, backed by one
WorkspaceSession. Do not give screens FakeHost, custody, or package signing APIs.

| App/Models protocol | Next-step adapter |
|---|---|
| HomeModel | Combine WorkspaceAPI snapshots into oldest-first Needs You groups. Load pendingDecisions on open/restart. Identity, workspace name and hosted marker come from the verified card/join, never the snapshot. Drop summaries await DropService. |
| WorkspaceModel | Map questions, tickets, members and Factory children from an entire verified snapshot. Each model consumes its own events stream; streams share the session poller. |
| QuestionReviewModel | loadReview/reread call review(questionID:). Retain that immutable QuestionReview behind the display projection. Render exact source text with OrchUI.SafeText, including option labels; never feed rendered markers back into signing. Use ReviewArming with injected monotonic elapsed time: select, full scroll-to-end, then 800 ms before sign calls decide(review, optionID:). Changed selection resets arming. |
| PairingFlowModel | Forward link submission, cancellation and human comparison actions to PairingCoordinator. Observe its states and construct the workspace session only from a verified JoinedHandle. Demo host/primary panels remain explicit human actions. |

Map accepted, alreadyAnswered(label:at:), questionChanged(hash:) and uncertain to
existing SignPhase states. questionChanged requires a new review and arming.
checkWhetherReceived invokes WorkspaceAPI.reconcile(decisionID:) with the persisted
decision ID; it must never call decide again or synthesize a review. A pending decision
is a submitted immutable answer, not an editable offline draft.

The composition/lifecycle owner calls setForeground(false) on lock/background and
invalidates the review model and its arming. Return to foreground starts refresh;
verified push/reconnect hints call refreshViews. Cancel stream consumers when their
screens disappear. Use verifiedReceiptMs for local last-checked display; checkedMs is
host time. Workspace removal ends that generation and requires discarding its models.
New-ticket forms retain one creationID across retries with exactly the same fields;
an edited submission needs a new ID. Keep offline compose data unsigned.

The App-side adapter is named `WorkspaceProjectionMapper` (to be implemented in
App/Models when replacing PreviewWorld). It maps `OrchClient.Question` and
`OrchClient.Ticket` to the App's same-named display types: hex IDs, B64U hashes,
milliseconds to Date, `in_progress` to `.inProgress`, `factory_epic` to
`.factoryEpic`, and the full resolution actor/time. It receives workspace identity
from the verified join. Keep the original QuestionReview for decide; display
projections never become signing input. A closed review is a successful read:
show `review.question.resolution` and disable arming.

All lifecycle controls are on `any WorkspaceAPI`: call `start()` when attaching
an API after launch, `setForeground(_:)` on lifecycle changes,
`invalidateReviews()` on lock, and `refreshViews()` for verified hints.
`start()` and each foreground entry re-drive every non-resolved decision once;
background reconciliation is refused. Use `reconcile(decisionID:)` for explicit
receipt checks and `try await pendingDecisions()` to load the durable list.
Propagate store/removal errors rather than interpreting them as an empty list.
`await api.verifiedReceiptMs` supplies the local receipt time. Each `events()`
subscription immediately receives the latest cached snapshot, if any, and the
current connection state, then shares the foreground poller. `.removed` ends the
stream and invalidates that generation's models.

A failed pre-send read produces `ViewError.offline` with no signed decision;
failures after dispatch produce `.uncertain`. Signing and envelope persistence
commit together. Never-dispatched rows cannot be sent by reconciliation.
Persist each new-ticket creationID atomically with its exact title/body/epic draft
before calling newTicket; retain that record until a verified result is saved.
After a lost response or restart call newTicket with that same saved submission:
it resends the pending envelope or reconciles with an idempotent fresh envelope,
removing the prior attempt. Returned fields must match the saved UTF-8 bytes.

## Status in the app (feat/ui-wiring)

Live in Demo: pairing (PairingCoordinator), Home/Workspace/Questions/Tickets (BridgeWorkspaceAPI snapshots and events), signing
(QuestionReview + decide), pending/uncertain decisions and reconcile, new tickets (one persisted creationID per exact draft),
Leave (LocalWipe), Reset/Leave Demo (DemoSetup.reset), Demo push (PushSimulator), share destinations/import (ShareBridge via ShareWorld).
Live Drop uses encrypted service transfers and awaited share import (details below). Simulated: terminal and two Demo sign controls: "Review fails to load" fails the
next review read in the app (nothing is signed or stored), and (Simulator only) "Locked" locks the simulated device key for one attempt and releases it
by itself after 2 s (the person unlocking the phone; retrying never unlocks anything). Ticket drafts live in the workspace directory
and go with the local wipe; a failed wipe is reported as "removal incomplete" and never as removed. An interrupted Demo reset is
finished at the next launch. Demo authority keys are in memory only (P3), so a Demo realm
left by an earlier launch is wiped at boot rather than resumed. Release ignores every debug flag (scripts/check-release-flags.sh).


Fix-round lifecycle and recovery behaviour:
- `LiveServices.lifecycle` is the authoritative per-workspace state: live, removing,
  removalIncomplete, or removed. Failed Leave stays quarantined until a successful retry.
  Home and the workspace header show its status; foreground, refresh, review/signing,
  reconciliation, ticket/Drop composition and share import refuse quarantined workspaces.
- Foreground/background API changes are serialized independently of cancellable refresh
  tasks. A suspended network refresh cannot delay background review invalidation.
- Ticket submission requires an atomic, protected draft write in an existing workspace
  directory. Write errors send nothing; no draft path recreates a wiped directory.
  A lost reply (including reopening the model) reuses the creation ID stored with the exact text.
- Failed Demo resets retain their runtime recovery context for subsequent resets. The
  persistent resetPending flag clears only after recovery succeeds. Leave without a runtime
  or for an unknown workspace reports incomplete.
- Closing pairing cancels invitation and begin tasks and invalidates their generation,
  including after joining; late invitation results cannot start panel observers.
- Leave blocks new workspace notification schedules, drains in-flight schedules, and
  removes delivered and pending Demo notifications before completion. Reset drains and
  purges the Demo realm too; boot recovery purges notifications from an earlier launch.
  OS notification objects stay inside completion handlers for Swift 6 / Xcode 16.4.

`AppTests/LiveLifecycleTests.swift` covers failed removal then foreground, background with
suspended refresh, failed-reset retry, draft write errors and lost-response retry, closing
pairing during invitation creation, and Leave notification draining/purge.

## Drop

Use `DropService` for verified objects, downloads and durable sends. Recover pending
uploads with `resumeUploads`; surface `failedUploads` for explicit retry or discard.
`discardUpload` and `discardShareJob` stop local sending. The UI must present the
outcome as "stopped sending", not "deleted": a PUT with a lost response may already
have committed, and that content remains on the relay. Share-job discard also
removes local staged plaintext. A fresh document seal may reuse an uncommitted
version after discard; the discarded sealed body remains blocked.

`DropService.setHook` is a test seam and must never be wired in app code.

The app now owns an observable `LiveDrop` beside each `LiveWorkspace`. Pairing retains
its verified card behind `JoinedWorkspace.makeDropService()`; screens receive no
signing material or FakeHost. Lists carry verified descriptors, while at most three
visible-row metadata verifications at a time supply names, plaintext sizes, MIME and transcript.
`metadataVerified` verifies the author/chain, unwraps and checks the DEK commitment, and opens metadata; it never fetches a blob or writes a file.
Unverified rows are neutral. Metadata is cached by generation/object/version and
is not re-fetched on ordinary refresh. Demo fixture aliases are presentation
mappings to actual objects; Laptop Sending is seeded through the public service.

`canUse`, generation ownership and operation revisions guard actions and publication.
Background dismisses previews and suspends service work. Service lifecycle epochs also reject old operations after reactivation. Leave/reset clear models
and invalidate the service before wipe; failed removal remains unavailable. Busy
locks preserve rows and show “Busy lock: try again”. Unknown removal and unavailable
keys fail closed without asserting removal. Cryptographic/integrity and client/store
rollback errors outside individual list rows latch an alarm, clear displayed plaintext, invalidate the service, and purge all workspace downloads. Share import errors pass through the generation-checked handler before ShareBridge receives them. Bad list rows get an alarm badge and latch a workspace warning while good rows remain usable.

Open uses the service's atomic Complete-protected object/version file directly.
`DropDownload.deadlineMs` comes from the persisted download transaction and is the
minimum of signed expiry and download + seven days. Active preview monitoring uses
the Demo clock and dismisses on expiry, lock, quarantine or a newer version. Empty
files have an explicit state; URL payloads stay literal text. QuickLook extensionless
file handling and its own caches still need a device spike; no unmanaged copy is made.

Compose keeps picked file/photo bytes only in memory; document reads happen inside security-scoped
access. Photo import tasks are owned and cancelled on dismissal, background, Leave/reset or destination loss; late results check cancellation and lifecycle before publication. Limits use actual byte counts. Note-only sends are UTF-8 and attached notes
are metadata transcripts. Each send uses one UUID with stable attachment UUIDs. `sealSend` commits every ciphertext upload row atomically before any network side effect; interruption before sealing completes stores nothing and shows “Not sent”. Pending draft bytes are cleared on background. `confirmedUploads` exposes durable success of the signed-descriptor read-back (signature and canonical bytes equal to what was sealed); a listed descriptor, a 2xx or a list state alone is never displayed as confirmed. Failed and pending uploads
retain their durable identities for Retry/Stop or foreground recovery. Inbox Claim is
explicit and operate-only; unavailable keys never imply that an item is unclaimed.

Foreground activation is serialized, then every non-removed workspace purges local files directly through WorkspaceContainer, even when Drop is unauthorized or invalidated. Usable workspaces then resume all
pending uploads, inspects results and reloads failures independently. Share recovery
awaits foreground work. ShareBridge awaits `importShareJob`; the service owns durable
completion and plaintext cleanup. Destructive preview import/stop implementations exist only on PreviewWorld, never as ShareWorld defaults. Failed jobs stay available for explicit Retry/Stop
and startup recovery. Only live operate-capable destinations are published; temporary
quarantine/scope loss neither journals removal nor redirects staged jobs.

Tests: `LiveDropTests` covers busy/unknown removal, alarms, late Leave/reset publication,
and foreground expiry/recovery. `DropSuspensionTests` exercises paused download,
unstructured upload and interrupted cleanup boundaries. Bounded Drop and Share UI
tests assert verified content, file/text sends, Claim permissions, Retry/Stop and
confirmation plus cleanup. The app never wires `DropService.setHook`. Demo restart
still wipes its realm; durable restart coverage remains in OrchKit integration tests.

Upload/import coalescing is lifecycle-epoch-aware and dictionary cleanup checks operation identity.
Invalidation cancels and drains tracked operations for at most one second; late work remains fenced by
its original epoch and tombstone checks. Authentication rechecks availability after session acquisition
and before relay side effects. Test gates release late arrivals and deadline failures end the test path;
completion is bounded as well. `DropLifecycleRegressionTests` covers cancelled-epoch resume, session
suspension, atomic multi-attachment sealing and metadata-only reads. QuickLook Share/Save suppression
remains a blocker before real data, recorded in `gaps.md`; no export change is included here.

## Demo notification trigger, push diagnostics, offline Leave

- Settings > Demo controls > "Send a demo question notification" (`demo.sendNotification`, result `demo.sendNotification.result`): asks for notification permission on first use, then seals a Demo push and runs it through PushSimulator into a local notification after 8 s (1 s under UI tests) so the tester can lock the phone. Denied permission shows "Open iOS Settings" (`settings.notifications.openSettings`).
- `OrchAppDelegate` is the `UNUserNotificationCenterDelegate` and presents banners in the foreground; without it iOS shows nothing while orch is open.
- `settings.push.diagnostics`: permission, APNs environment and token / pending / failure text (no token value). Real APNs registration is attempted only for non-Demo installs with permission allowed; Demo never registers.
- Leave offline: the local wipe never depends on the host. Pending server cleanup is listed under "Finish on your Mac" (`settings.serverCleanup.<ws>`, `settings.serverCleanup.retry`); `removalIncomplete` (`settings.leave.incomplete`, with `settings.leave.failure`) means a genuine local wipe failure only.
