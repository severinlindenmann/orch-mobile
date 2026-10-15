# Host API v1: the phone over column R

Status: C2a (reads), 15 Oct 2026. Source of truth: orch-core `docs/architecture/orch-v2-host.md` section 11A.5 "As built in R2" (the framing
sheet), 11A.4 (column R), section 0.8 (op schemas), 11A.14 (phone person events). Vectors: `OrchKit/Tests/OrchTestVectors/r2/r2_framing.json`
(provenance and sha in `PROVENANCE.md`). Supersedes [host-api-v0.md](host-api-v0.md). Writes (`relay.submit`) are C2b.

## Framing

A call is one sealed bridge request (relay protocol 8.6). The sealed meta is exactly `{"op", "args", "idem"?, "rd"?}` with `data` empty:

- `op` is a key of the closed table (`R2.ops`): the reads `ticket.query`, `ticket.get`, `ticket.text`, `needs`, `activity.list`, `workspace.show`,
  `workspace.settings`, `member.list`, `whoami`, `outcome.get` (scope `look`) and the writes `new_ticket`, `answer` (scope `decide`, C2b).
  Anything else is `forbidden_scope`.
- no `auth` key, no grant-shaped string anywhere (`R2.checkMeta` is the host's check, run by the phone on what it builds and by FakeHost on what it
  receives);
- `idem` on every write (the event id), never on a read;
- `rd` (H12d) is a meta field, sealed, a sibling of `op`: one injection point (`ReaderRD`), on for paired sessions. `reader.declare` (H12d-3, core #555)
  is a READ in the table: `{"op":"reader.declare","args":{"reader_decl":{...}}}`, no `idem`, no `rd`; the answer's `digest` is persisted in the reader state
  and is the `rd` from then on (until then the pair declaration's own digest). On `declaration_unknown` the phone declares again and sends the
  original request once more under a new rid; `no_declaration`, `reader_too_old` and `reader.decl_invalid` are class D, never retried, and the App
  shows "Update orch to open this workspace". `blocksUntilDeclared` is off for paired sessions, so a missing declaration sends no `rd` and blocks
  nothing locally; a corrupt or foreign declaration, or a level below the stored marker, refuses every request before it is sealed.

The answer: chunk 0 meta exactly `{"status":"ok"}` and later chunks `{}`, data across the chunks `cj(Result)` (at most 2 095 587 bytes), or one
`LAST | REFUSAL` chunk whose meta has exactly the per-code field set (`HostRefusal(meta:)`): proto codes with `high`, `host_ms`, `epoch`, `status`;
every host code with `retryable` (derived from its class, checked), `seqs` only for landed events, `next_key` only for `ticket.key_not_next`.

## Retry classes of a read

Table-driven from `PhoneRetryTable` (checked against the vectors' `retry` table): A (`busy`, `store.busy`, stale answers, ...) is sent again, at most
three times with 1, 2, 4 s; B (`already_done {status: unknown}`, `rid_conflict`) re-issues the read under a NEW rid, at most twice; C and D are
definite. Reads take no `idem` and leave nothing to settle, so a read that gets no answer is dropped and the next poll asks again.

## Op mapping (what the screens get)

| Screen data | Ops | Mapping |
|---|---|---|
| Needs you (open questions) | `needs`, then `ticket.get` per ticket with a question | `needs` names the person's open questions; `ticket.get` gives the F1 question (`qid`, `hash`); the phone recomputes both and refuses a mismatch. `QuestionOption.id` is the option `key`. |
| Question review | `ticket.get {ref}` | `F1Question.reviewed(ticketUID:workspace:basedOn: doc.head.head, rosterV: members_v)`: the only way to a `QuestionReview.reviewed` (prepared for C2b). A closed question carries `answer.signer {device, auth}`; the device label comes from `member.list`. |
| Answered history | `activity.list {types: [question.answered]}` then `ticket.get` | tickets are re-read only when their `head_seq` (from `ticket.query`) changed. |
| Tickets | `ticket.query` (paged, at most five pages) | `Ticket(row:)`: titles only (no body travels in R2). Host statuses map to open / in progress / done; `epic` is a factory epic. |
| Members, workspace | `member.list`, `workspace.show` | devices and labels; `next_key` (advisory, `null` without `decide`). |
| Change detection | `activity.list {limit: 1}` | `wait` is not served: the `sub_cursor` is compared every 15 s (backing off to 60 s); the snapshot is read again only when it moved. |

Unsigned host views ignore unknown keys; every bound or displayed field is required and typed (`HostReads`). `reader.list` has a parser but is
not in the closed table, so it is not called.

## What stays interim until C2b

The sign sheet still sends the v0 detached `decision` op and the new-ticket flow the v0 `new_ticket` op, against FakeHost only; a real R2 host
refuses both. C2b replaces them with person events signed over `relay.submit` (11A.14), using `QuestionReview.reviewed`, `members_v` and `next_key`
from these reads.
