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
Simulated: Drop (no Drop service yet; labelled in the UI), terminal, and two Demo sign controls: "Review fails to load" fails the
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
