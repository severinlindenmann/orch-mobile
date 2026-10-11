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

## Drop

Use `DropService` for verified objects, downloads and durable sends. Recover pending
uploads with `resumeUploads`; surface `failedUploads` for explicit retry or discard.
`discardUpload` and `discardShareJob` stop local sending. The UI must present the
outcome as "stopped sending", not "deleted": a PUT with a lost response may already
have committed, and that content remains on the relay. Share-job discard also
removes local staged plaintext. A fresh document seal may reuse an uncommitted
version after discard; the discarded sealed body remains blocked.

`DropService.setHook` is a test seam and must never be wired in app code.
