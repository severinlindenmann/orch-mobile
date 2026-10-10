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
checkWhetherReceived invokes the session's reconciliation service with the persisted
decision ID; it must never call decide again or synthesize a review. A pending decision
is a submitted immutable answer, not an editable offline draft.

The composition/lifecycle owner calls setForeground(false) on lock/background and
invalidates the review model and its arming. Return to foreground starts refresh;
verified push/reconnect hints call refreshViews. Cancel stream consumers when their
screens disappear. Use verifiedReceiptMs for local last-checked display; checkedMs is
host time. Workspace removal ends that generation and requires discarding its models.
New-ticket forms retain one creationID across retries with exactly the same fields;
an edited submission needs a new ID. Keep offline compose data unsigned.
