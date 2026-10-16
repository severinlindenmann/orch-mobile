# F1 phone person events (orch-core host section 11A.14)

Protocol layer in `OrchKit/Sources/OrchProtocol` (`F1Question`, `F1Text`, `PhoneEvents`, `PhoneRetry`) plus `OrchClient/PhoneEventIDs`. Answers are wired
into `WorkspaceSession` / `BridgeWorkspaceAPI` since C2b (see "Answer write path" below); creation follows in increment 3. Vectors: `OrchKit/Tests/OrchTestVectors/f1` (PROVENANCE.md).

## Gate for the sign-sheet PR (Opus MEDIUM-2)

The F1 sign sheet must NOT render host or phone-authored text raw. It MUST route every one of these through SafeText / look-alike marking:

- the question `text` and `why`;
- every option `label` AND `cost` (cost is bound by the hash, so it is rendered and treated like a label);
- the answer option label shown for the chosen option;
- phone-authored text: the free-text answer and the ticket title (after `PhoneEvents.prepareText`).

Labels and costs fail closed: a label or cost the sheet cannot render safely refuses the review (no sign sheet), per 11A.14 14.5 ("never signs what it did not render").
`AnswerDisplay`/`CreationDisplay` equality for the auto re-sign is byte-exact; the sheet must show the same strings it signs.

The caller must pass `basedOn` (`doc.head.head`) and `rosterV` (`members_v`) to `F1Question.reviewed` from the SAME `ticket.get` snapshot as the question itself.

A core-parity `suspicious()` (invisible and bidi marking as in orch-core `canon/text.py`) needs data the phone does not have yet: `MARK_RANGES` (leading mark) and
`CF_RANGES` (format characters) from orch-core `_unicode16.py`. Plan: add both blocks to `BLOCKS` in `Scripts/gen_unicode16_swift.py`, regenerate, and port `suspicious()` and
`show_invisible()` with core's vectors (`text.json` has no `suspicious` cases yet: ask core for some).

## Tracking

- The retry table (`PhoneRetryTable`) is a hand copy of the 14.4 table. When R2 publishes the shared data file ("a shared data file that both the R2 tests and the phone read"),
  replace the sets with that file and add the test that every code R2 can emit is in it.
- Unknown keys: Question, answer and signer objects ignore unknown host keys (section 0.4); option entries are closed because they are hashed.
- Never use Foundation `precomposedStringWithCanonicalMapping` on a signed or hashed path (`FieldRules.noFoundationNFCInOrchProtocol`).

## Answer write path (C2b increment 2, PR #83)

- **Entry.** `WorkspaceAPI.answer(snapshot, option:)` signs an `answer` person event to exactly the `ReviewedSnapshot` of one fresh
  `ticket.get` (options only; a question without options is answered on the Mac). The op maps to `relay.submit` with scope `decide`;
  `R2.writeMeta` is the only meta builder.
- **Storage (migration 15).** `pe_reviews`: one row per review, pointing at its current attempt by compare-and-swap (`current_idem`,
  `ver`); at most one `active` review per question (unique index). `pe_attempts`: one immutable row per idem with the exact signed event
  bytes (the only bytes ever framed for it), the window clock facts, the monotonic `dispatched` marker and append-only evidence. Triggers
  keep signed fields immutable, `landed` final, `dispatched` monotonic, a dispatched attempt undeletable until settled, and evidence
  append-only. Every write row of `bridge_requests` names its attempt.
- **Lifecycle invariant (`LifecycleFence`).** A signature, and the first dispatch of an attempt, happen only while the lifecycle is still
  valid at the moment of the effect: checked synchronously inside the signing transaction right before `PhoneEvents.sign`, and in `post`
  right before `bridgePost`. Background, `.inactive`, protected-data loss, a custody lock, `invalidateReviews`, a realm or generation
  change all invalidate it. An automatic re-sign also needs the review's in-memory eligibility token (never persisted: a relaunch means
  a new review).
- **Window.** Sent only while age = max(host age, wall age, monotonic age) <= 840 s and the id is at most 300 s ahead. Past it nothing is
  sent; settlement only reads.
- **Settlement.** By reading: the direct `Result`, then `outcome.get` (`pending` stays "checking" at any age), then the log for
  `idem.expired` / `outcome.unknown_idem` after the bound. A landing of ANY attempt of the review (an earlier, superseded one included)
  wins and is final. C-auto (`members.stale`) is re-signed automatically at most 3 times, only if nothing displayed changed; C-review asks
  for a new review; D is refused. A failed confirming read leaves the review `landed` and is retried; `landed_unconfirmed` means a
  successful read that shows something else.
- **Live (increment 4).** `RealmCapabilities.live.writes` is on. A Live write is admitted only when the host's column-R `whoami.relay`
  lists the op at version 1 with `r6_ready` true (read at `startViews`, on foreground and on an epoch change; in memory only; cleared on
  background, a failed read or an epoch change; absent means no). The check gates a new signature and the first dispatch, never a resend or a
  settlement read. The Live policy also requires a Secure Enclave identity; this is application enforcement, not cryptographic attestation.
- **Lifecycle (one rule for a tap).** The first dispatch of a tap needs a lifecycle that did not end for its review since the Sign tap: a tap
  stopped before its first charge ends as "not sent" and is never sent later, whichever of the fence and the actor hop got there first (a
  relaunch recovering already signed bytes is not such an end).
- **Creation.** No new creation review while a signed creation is unsettled (`checkCreation` stays "checking" when the workspace is not
  usable and a draft review exists; `reviewCreation` refuses while the draft holds a review), and the creation sheet has no Sign button when the
  title or workspace name has hidden or look-alike characters.
