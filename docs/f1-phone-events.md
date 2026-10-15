# F1 phone person events (orch-core host section 11A.14)

Protocol layer in `OrchKit/Sources/OrchProtocol` (`F1Question`, `F1Text`, `PhoneEvents`, `PhoneRetry`) plus `OrchClient/PhoneEventIDs`. No UI, no networking, not wired
into `WorkspaceSession` / `BridgeWorkspaceAPI` (the host-api v1 switch waits for R2 #467 framing). Vectors: `OrchKit/Tests/OrchTestVectors/f1` (PROVENANCE.md).

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
