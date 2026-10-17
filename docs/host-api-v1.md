# Host API v1: the phone over column R

Status: C2a (reads), 15 Oct 2026. Source of truth: orch-core `docs/architecture/orch-v2-host.md` section 11A.5 "As built in R2" (the framing
sheet), 11A.4 (column R), section 0.8 (op schemas), 11A.14 (phone person events). Vectors: `OrchKit/Tests/OrchTestVectors/r2/r2_framing.json`
(provenance and sha in `PROVENANCE.md`). Supersedes [host-api-v0.md](host-api-v0.md). Writes (`relay.submit`) are C2b; their Live enable is the `whoami.relay` signal below.

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

## Caps, truncation and what the phone cannot show

Per snapshot: at most 5 pages of `ticket.query` (200 rows each), at most **30 `ticket.get`** reads (tickets with an open question for this person
first, then the tickets of the newest answers), and the answered history is the newest **50 feed items** (`activity.list`, `question.answered`)
of which at most 20 tickets are read. Anything beyond is not read and not re-read every snapshot (a cached read stays valid while the ticket's
`head_seq`, or for an unlisted ticket the feed cursor, did not move). The budget is checked between steps, so a snapshot never eats the 64-slot
mutation reserve. A cut list says so: `WorkspaceSnapshot.ticketsIncomplete` (page cap, or fewer rows than the host's `total`; the App shows
"Showing the newest tickets only"). Open questions the phone cannot show or sign (unreadable, a failed label or hash check, free text, or beyond the
`ticket.get` cap) are counted in `macOnlyCount` and shown as "N questions need your Mac"; none is signable.

## One enforcement point per invariant

- The closed op table: `prepare` runs `R2.checkMeta` on every R2-shaped meta (and on every meta under a Live config, `enforcesOpTable`), before any
  signature or seal. Live sends no interim v0 write: `submit` and `createTicket` refuse with `writesUnavailable`, and the Live capability
  `writes` is off, which hides the sign sheet and New ticket. Demo keeps both.
- Read failures: `callRead`'s error exit drops the identity caches (labels, question index, ticket reads) and, for a sealed reader refusal,
  also ends the cached view and emits `readerRefused` (the App shows "Update orch to open this workspace"). Every read path goes through it, the
  poller's feed read included. Every attempt row of a read is discarded whatever the outcome. A read accepts only R2 framing.
- Reader state: the downgrade marker and the stored declaration are checked on every request (only the `rd` injection is exempt, for
  `reader.declare`); a declare answer is accepted only for this device and the declared level, and a fresh declaration after
  `declaration_unknown` is made at most once per 5 minutes.
- Keys: one shape for every parsed key, `[A-Z][A-Z0-9]{1,9}-[0-9]{4,}` (`validTicketKey`). Only the advisory `next_key` of a
  `ticket.key_not_next` refusal is checked loosely (`advisoryKeyHint`; the R2 vector carries `DEMO-42`). `workspace.show.next_key` is strict.
- Option `cost` is bound in the question hash with the label, so it is shown wherever the label is (option rows, the sign sheet).

## Live write signal (`whoami.relay`, C2b increment 4)

Source: orch-core host changelog 57 and `Dispatch._relay_caps` (column R only). `whoami` answers `{peer, person, tier, grant, session, relay}` with

```
relay: {ops: {"answer": 1, "new_ticket": 1}, r6_ready: bool, dev?: {sim_convenience: true, sandbox: "<id8>"}}
```

`ops` lists the person-event write kinds the host serves on R with their versions; `r6_ready` is the live R6 gate (`false` while R6 is dormant).
`WhoAmIResult.relay` parses it leniently: an absent or malformed `relay` (or one without `ops` as an object and `r6_ready` as a bool) is
`nil` and never fails the read; a malformed op value drops that op only. `dev` is not read by the phone yet (the Simulator lane, increment 5).

`HostWriteSupport` is held by the session in memory only (never persisted). It is read at `startViews`, on every foreground and on an
epoch change; it is cleared on background, on an epoch change and on a failed read, so the phone fails closed. `hostWritesAllowed(kind)`:
Demo is unchanged (FakeHost serves both kinds); Live needs `ops[kind] == 1 && r6_ready`. It is checked for a new signature (review, tap,
automatic re-sign) and for the first dispatch of an attempt; a resend, a reseal and settlement reads are never blocked by it. FakeHost emits
`relay` with toggles (`setRelayCaps`: absent, `r6_ready` false, ready).

## What stays interim

In Demo the FakeHost serves `answer` and `new_ticket` as person events over `relay.submit` (11A.14) like a real R2 host. Live offers them only
under the three conditions above; until the R6 gate flips on a real host, `r6_ready` is false and Live shows "Your Mac's orch doesn't accept
answers from iPhone yet. Answer on your Mac."
