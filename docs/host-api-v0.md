# orch mobile host API v0

Status: provisional, 10 October 2026. This is an implementation contract for OrchClient and
OrchFakeHost, pending host P2 and relay P3 agreement; it is not a protocol-v2 amendment.
[Decisions](decisions.md) win over proposals; [challenge](challenge-codex.md) obligations apply.
Protocol references below mean [orch-relay protocol v2](/Users/severin/orch-dev/orch-relay/docs/protocol-v2.md).
Vector paths mean [vectors_v2.json](/Users/severin/orch-dev/orch-relay/tests/vectors_v2.json), `suites."2"`.
Gap references link to the [numbered gap table](gaps.md); row numbers are part of each reference.
Local P1/P2/P3 principle labels mean decisions.md; host P2/relay P3 mean upstream delivery phases.
Do not declare interoperability until those rows are resolved and adapters tested against P2/P3.

## 1. Layers and version boundary

The phone uses suite 2, CryptoKit/Secure Enclave custody on device and software custody on Simulator.
Demo traverses the real canonical JSON, crypto, bridge, pairing, grant and push implementations.
Only RelayTransport changes between an in-process FakeRelay and a future HTTPS implementation.
Semantic changes may still be necessary when upstream resolves provisional contracts (P5).
Screens receive WorkspaceAPI, DropService and PairingCoordinator; they never receive FakeHost.
PreviewWorkspaceAPI is for previews only, never Demo or integration tests.

Except for the existing protocol §10.6 Drop PUT and §10.5 claim routes, relay routes start `/v2`
(protocol-v2 §19, P3-D1). There is no relay adapter version: relay requests and responses carry neither
an `Orch-Host-API` header nor a `host_api` field, and JSON field sets are exactly those listed (§19.6).
Errors are always §14's `{"error": code, ...}` (strict §2.3 JSON); there are no adapter-only errors.
`Retry-After` is integer delta-seconds only (HTTP dates are ignored).
The `host_api: 0` field inside bridge-tunnelled HOST views (`/v2/snapshot`, `/v2/tickets/{key}`,
`/v2/questions/{id}`, `new_ticket`, `decide` data below) is a different thing: those are the host's
sealed response data, never a relay route, and keep their provisional version field unchanged.
Never add `host_api` to a certificate, grant, card, pairing meta, decision or §14 refusal.
Strict §2 encodings apply: hex16 ids, canonical b64u bytes, integer milliseconds, no duplicate keys.
JSON examples use `$name` for typed placeholders, not literal values; listed field sets are exact.
`Signed<T>` below means the unchanged protocol object, including the card's special outer shape.

### Swift boundary

These are the exact proposed signatures, not claims that implementations already exist.
All supporting values are immutable Sendable structs/enums; keys are custody handles, never raw scalars.
Data below is an untrusted byte buffer, not a decoded protocol object. Transport does no crypto.
A transport is constructed with a fixed RealmContext and allowed origin; callers cannot override either. The transport
exposes that context (`var context: RealmContext { get }`) and a login is bound to it: the client signs `context.origin`
(there is no origin parameter on `openDeviceSession`) and only with a device identity whose realm tag equals
`context.realm`, both checked before the first request. A wrapper transport must report the context of the transport that
really carries its bytes. Device identities carry the realm of the custody that produced them (set only in-package), so a
wrapper custody cannot present live keys as Demo's, or the reverse (`RealmViolation.wrongStore`).

```swift
import Foundation
import OrchProtocol

public struct WireReply: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
}
public struct RelaySession: Sendable { public let token: String }
public struct PairRoute: Sendable {
    public let workspaceID: ID16
    public let offerID: ID16
    public let requestID: ID16
}
public struct BridgeRoute: Sendable {
    public let workspaceID: ID16
    public let requestID: ID16
}
public protocol RelayTransport: Sendable {
    var context: RealmContext { get }
    func challenge() async throws -> WireReply
    func login(_ body: Data) async throws -> WireReply
    func pairingPost(_ envelope: Data, route: PairRoute) async throws -> WireReply
    func pairingPoll(route: PairRoute, after: UInt64?) async throws -> WireReply
    func bridgePost(_ envelope: Data, route: BridgeRoute, session: RelaySession) async throws -> WireReply
    func bridgePoll(route: BridgeRoute, after: UInt64?, session: RelaySession) async throws -> WireReply
    func grants(workspaceID: ID16, epoch: UInt32?, session: RelaySession) async throws -> WireReply
    func memberList(workspaceID: ID16, session: RelaySession) async throws -> WireReply
    func card(workspaceID: ID16, session: RelaySession) async throws -> WireReply
    func cardKey(workspaceID: ID16, cardSequence: UInt32, session: RelaySession) async throws -> WireReply
    func registerPush(_ body: Data, session: RelaySession) async throws -> WireReply
    func unregisterPush(_ body: Data, session: RelaySession) async throws -> WireReply
    func revocation(deviceID: ID16) async throws -> WireReply     // session-less: a public, PK-signed record
    func dropPut(objectID: ID16, ifMatch: UInt32, body: Data,
                 session: RelaySession) async throws -> WireReply
    func dropList(_ query: Data, session: RelaySession) async throws -> WireReply
    func dropGet(objectID: ID16, version: UInt32, part: DropPart,
                 session: RelaySession) async throws -> WireReply
}
public enum DropPart: String, Sendable { case descriptor, wraps, blob }

public protocol WorkspaceAPI: Sendable {
    func snapshot() async throws -> WorkspaceSnapshot
    func review(questionID: ID16) async throws -> QuestionReview
    func decide(_ review: QuestionReview, optionID: String) async throws -> DecisionOutcome
    func pendingDecisions() async -> [DecisionStatus]
    func newTicket(_ draft: NewTicketSubmission) async throws -> Ticket
    func events() async -> AsyncStream<WorkspaceEvent>
}
```

WorkspaceAPI is bound to one `(realm, workspace, generation)` at construction.
WorkspaceSnapshot, Ticket and NewTicketSubmission have exactly the fields specified in §2 below.
QuestionReview is created only by WorkspaceSession after an authoritative question re-read and hash
recomputation. It contains the exact question text/options/hash, question ID, realm/workspace/generation
and an opaque session-issued review identity; it has no public initializer and contains no signed operation.
`decide` validates that review, current generation, open state and selected option; WorkspaceSession alone
uses package-scoped DeviceIdentity signing custody, signs the §13 op, persists it and sends it.
Screens have neither custody nor a pre-signed-decision API. Lock/background invalidates unsent reviews.
DecisionStatus exposes persisted decision ID, question ID, selected option and pending/uncertain/resolved
outcome; pendingDecisions reloads unresolved submissions after restart without signing again.
DecisionOutcome is `accepted`, `alreadyAnswered(label:at:)`, `questionChanged(hash:)`, or `uncertain`.
WorkspaceEvent is `snapshot(WorkspaceSnapshot)`, `invalidated`, `connection(ConnectionState)`, or `removed`.
ConnectionState is `online`, `offline`, or `reconciling`; events are local hints, never signed authority.
Each events() call returns a fresh single-consumer AsyncStream, with its own cancellation handling.
WireReply header names are case-insensitive; normalize names and reject conflicting singleton values.
A non-nil grants epoch must be >= 1; reject 0 before I/O (epoch 0 is reserved for pairing envelopes).
Transport throws for cancellation, I/O and realm violations; HTTP failures remain WireReply values.
BridgeWorkspaceAPI verifies before decoding, and throws typed protocol/adapter failures, never raw HTML.
Its WorkspaceSession actor owns seq allocation, pending rid records, epochs, offsets and polling.
Persist before sending; perform no await inside a store transaction. No partial snapshot is published.

| Method | Protocol responsibility; missing transport/mapping |
|---|---|
| challenge, login | §12.2 bytes/checks; route and login JSON provisional v0, gap 23 |
| pairingPost, pairingPoll | §8.3–8.4, §8.9; route/poll wrapper provisional v0, gap 22 |
| bridgePost, bridgePoll | §8.1–8.2, §8.5–8.9; HTTP/mailbox adapter provisional v0, gap 25 |
| grants, memberList | §7.2–7.3 unchanged objects; fetch routes provisional v0, gap 24 |
| card, cardKey | §7.1 and §5.3; CK fetch provisional v0, gap 29 |
| registerPush, unregisterPush | §9 payload unchanged; registration provisional v0, gaps 14–16 |
| revocation | §6.2 PK-signed record; fetch route provisional v0, gap 24 |
| dropPut, dropList, dropGet | §10 objects/checks; packaging/list/get provisional v0, gap 25 |
| snapshot, review | provisional v0 host view through §8.7 http, gaps 25, 27 |
| decide | §13 exact decision op; success/reconciliation projection provisional v0, gap 25 |
| newTicket | §8.7 names new_ticket, fields provisional v0, gaps 9, 25 |
| events | local polling/invalidation contract, provisional v0, gap 25; no invented wire event op |

### Common relay adapter

Let `R = /v2` (protocol-v2 §19). Request and response bodies are the exact field sets shown, with no version field.
`POST R/session/challenge` has `{}` and returns `{"challenge":"$b64u32","expires_ms":$ms}`.
`POST R/session/login` has `{"challenge":"$b64u32","kind":"device",
"id":"$device","sig":"$b64u64"}`; workspace actors use `kind:"workspace"`.
Response: `{"token":"$opaque","expires_ms":$ms}`. Directory supplies cert/card.
`POST R/session/logout` (device or workspace token) has `{}` and returns `{}`; it is idempotent and is 200
for an unknown, expired or already-logged-out token. Session JSON bodies are capped at 16 KiB (413 `too_large`
before parsing); at most eight live tokens per device (429 `quota_exceeded` with `Retry-After`).
Signature bytes, own-origin binding, challenge consumption on every attempt, 60-second challenge and
15-minute session lifetime are exactly §12.2. Session is per relay+realm, authorized per workspace list.
There is no additional JSON signature or seal; HTTPS protects bearer/token bodies in live transport.
Use §14 HTTP errors for all failures; `unauthenticated` is HTTP 401 (§19.6).
Confirm route shapes, session scope and credential lookup with P3 ([gap 23](gaps.md)).

Authenticated calls use `Authorization: Bearer <token>`. Tokens stay in app-only custody, not logs/NSE.
`POST R/workspaces/{ws}/bridge/{rid}` carries raw ORB2 bytes, returns 202 with `{}`.
`GET` on that route polls; optional `after` is the last received chunk index (absent before chunk 0).
Response: `{"chunks":[{"id":"$rid","idx":0,"last":true,"stream":false,
"envelope":"$b64uORB2"}]}`. An empty list means no available chunks, not host approval or refusal.
Poll is non-consuming; retain sealed bodies 60 seconds (§8.9). Validate clear fields against the header.
Route/header mismatch is 400 `malformed`; bad membership/session is 403 `not_eligible`/401 `unauthenticated`.
Bridge refuses inside signed/sealed envelopes; relay HTTP errors never count as verified host refusals.
Ordinary limits: request 1 MiB, chunk 256 KiB, meta 64 KiB; incomplete responses fail as a whole.
A body over its cap is 400 `too_large` before parsing (§19.6); `wait` (0–25) is accepted on the poll.

**Bridge delivery (protocol-v2 §19.3 P3-D8/D9/D22, §19.6).** The relay keeps a replay record per
`(ws, device, rid)` for 900 s from the FIRST receipt; resends never extend it (a dependent copy or chunk
does, `keep_until_ms`). An identical resend is coalesced (202, nothing queued) while a live copy is
undelivered (above the host's acknowledged cursor); otherwise it is requeued at most once per 10 s
(429 `rate_limited`, `Retry-After` = rest of the interval rounded up) and at most 8 times, then 409
`retry_exhausted` (terminal). Other bytes for a known rid are 409 `rid_conflict`. A NEW rid whose
header epoch is not the current list epoch is 409 `stale_epoch {"epoch"}`, an unsigned hint; a known
rid skips the epoch check. Host chunks need a known, unexpired rid (else 410 `expired`), the request's
epoch (an old epoch only as `LAST|REFUSAL` or a byte-identical stored replay, else 409 `stale_epoch`);
other bytes at a stored index are 409 `chunk_conflict`; a stored replay never refreshes a TTL or
resurrects an expired body. The phone (`WorkspaceSession`):
- after 202 or 429 keeps polling the SAME rid and never reissues under a new rid; with no answer the
  request stays pending (`noResponse`, or the 429 refusal) and `resend` sends the same bytes (a 503
  queued nothing: surfaced at once, still pending);
- after 409 `retry_exhausted` keeps polling while the relay retains a copy, then marks the attempt `uncertain`
  together with an `exhausted` marker (one transaction) and throws `SessionError.retryExhausted`; nothing
  is re-sent automatically. Such a decision is `needsRetry` (`DecisionOutcome`/`DecisionState`): automatic
  reconciliation only reads the question; `retry(decisionID:)` ("Send again") is the explicit retry;
- on 409 `stale_epoch` never raises the epoch from the hint: it refetches the SIGNED grants and member
  list (only hints count: at most 3 starts per sliding 60 s, then 20/40/60 s, reset after 120 s without a
  hint or on a newer signed epoch; `EpochRefetchLimiter`, `SessionError.epochRefetchDeferred`). If the
  signed list confirms a newer epoch, a FIRST attempt is re-sealed under the SAME rid, but only within 240 s
  of its first copy (later: `uncertain`, reconcile). A host that ran a copy a relay delivered anyway answers
  `rid_conflict` → `uncertain`, keeping the ORIGINAL attempt. Without a newer signed epoch:
  `awaitingSignedEpoch`, still pending. A resend refused by the hint, and 410 `expired`, give `uncertain`;
- re-signs under a new rid only after a sealed host refusal that says the request did not run
  (`stale_epoch`, first `stale_timestamp`, `stale_sequence`, §8.5) and never on a resend (U8).
  `not_visible` is terminal and definite: a decision ends `notApplied`; other ops get the typed refusal.

## 2. Host view and mutations (provisional v0)

Bridge `http` meta is exactly `{"op":"http","method":"GET","path":"/v2/snapshot","headers":{}}`.
The only allowed headers are none; data is empty. No arbitrary URL, cookie, origin, host or forwarding.
Other allowed paths are `/v2/tickets/{key}` and `/v2/questions/{question_id}`.
Files use DropService exclusively; there is no host-view Drop projection.
Keys match `[A-Z][A-Z0-9]*-[1-9][0-9]*`; reject queries, percent escapes and traversal in v0.
These `/v2` paths follow gap 25's provisional naming; their representation is **host API 0**, not v2 JSON.
Success chunk 0 has `{"status":200,"headers":{"content-type":"application/json"}}`;
subsequent meta is `{}`, with LAST on the final chunk. Canonical JSON is in data, never in a new meta op.
Requests use dk_sig + K_bridge(current); all responses use WSK + that request's K_bridge (§8.2).
No additional detached signature for a snapshot or ticket. Host projections are not workspace identity.
Scope mapping chosen here: reads require `look`; decisions require `decide`; new tickets require `operate`.
Scope prefixes still obey §6.1. Confirm mapping and exact schemas with P2 ([gaps 9, 25, 27](gaps.md)).

Snapshot response:
```json
{"host_api":0,"workspace_id":"$ws","revision":1,"checked_ms":$ms,
 "questions":[],"tickets":[],"members":[]}
```
`revision` is a persisted, monotonic host-view counter; reads are one consistent host snapshot.
`checked_ms` is host time, not proof of current connectivity; phone also records verified receipt time.
`questions` includes open and closed questions; no pagination in bounded Demo fixtures.
A question has this shape (null values are mandatory, not omitted):
```json
{"question_id":"$id","ticket":"MOB-1","text":"Ship this change?",
 "options":[{"id":"approve","label":"Approve"},{"id":"reject","label":"Reject"}],
 "content_hash":"$b64u32","created_ms":$ms,"state":"open","resolution":null}
```
Closed state is `"closed"`; resolution is `{"decision_id":"$id","answer":$json,
"by_device_id":"$device","by_device_label":"Demo iPhone","at_ms":$ms}`.
The core question fields and hash are §13; options schema and resolution projection are provisional.
Hash exactly `{question_id,ticket,text,options}` with `orch/v2/question|`, never these extra view fields.
In v0 the answer is exactly `{"option_id":"approve"}` (one of the question's option ids).
`GET /v2/questions/{id}` returns `{"host_api":0,"workspace_id":"$ws","question":$question}`.
Unknown id/key returns signed/sealed HTTP status 404 data `{"host_api":0,"error":"not_found"}`.
This local error is not a new bridge refusal. Disappeared questions invalidate review; never infer acceptance.

Ticket projection:
```json
{"key":"MOB-1","title":"Review mobile pairing","body":"Compare both codes.",
 "state":"open","kind":"ticket","epic_key":"FAC-1","updated_ms":$ms}
```
Ticket state is `open|in_progress|done`; kind is `ticket|factory_epic`; `epic_key` is key or null.
`GET /v2/tickets/{key}` returns `{"host_api":0,"workspace_id":"$ws","ticket":$ticket}`.
WorkspaceAPI exposes snapshot, review, decide, pendingDecisions, newTicket and events; ticket detail
uses the snapshot ticket in v0. `review(questionID:)` uses the question GET above, never cached push text.
Members are `{"device_id":"$id","label":"Demo Mac"}` from host pairing registry (gap 27).
Authorization/scopes come from the verified signed member list, never this label projection.

`new_ticket` meta is provisional: `{"op":"new_ticket","host_api":0,"creation_id":"$hex16",
"title":"$text","body":"$text","epic_key":null}`; data is empty.
Title is 1–200 Unicode scalars, body 0–20,000; reject invalid/unsafe input rather than silently rewrite it.
`epic_key` must name a Factory epic in this workspace. Reply is HTTP-style 201 data
`{"host_api":0,"creation_id":"$id","ticket":$ticket}` in the normal bridge response.
Host atomically stores `(device_id, creation_id, canonical request, ticket)` with the ticket indefinitely
in v0; identical logical retries return the same ticket. Changed fields return signed/sealed HTTP-style
409 data `{"host_api":0,"error":"creation_conflict"}`, not a bridge refusal. `rid_conflict` remains
reserved for the same rid with different bytes. The provisional new_ticket meta explicitly permits
`host_api` as an adapter-schema exception; no established signed protocol object's shape changes.
Confirm this new_ticket schema with P2, gap 25.
Use new rid/seq when resealing after stale_epoch, retaining creation_id and exact ticket fields.
There is no invented detached ticket signature or question-style sign sheet (gap 9).
User explicitly submits the compose form; offline saves an unsigned draft only.

`decide` sends the exact §13 `{op,decision_id,question_id,content_hash,answer,sig}` without host_api.
Host verifies the detached dk_sig signature before compare-and-set, then records the decision atomically.
Provisional success data is `{"host_api":0,"decision_id":"$id","question":$closedQuestion}`.
Later logical decisions receive §14 `already_answered` with only by_device_label/at_ms.
An identical-envelope retry first follows the existing rid replay path, before timestamp checks.
Changed question receives `question_changed` with content_hash; fetch again and require a new review.
Persist immutable review, decision_id, answer, detached signature and envelope before the first send.
After a lost response, first resend the stored envelope byte-for-byte with the same rid/seq/salt;
the host replays its recorded response while the rid record lives (received_at + 900 s, §8.6 step 5).
Under protocol-v2 the relay delivers that replay only while the original answer chunk lives (60 s):
an expired chunk is never resurrected (P3-D22), so a later resend gets no answer and ends `uncertain`.
On `already_done(unknown)`, unknown-rid `stale_timestamp`, or expiry of that 900-second window, fetch
the question: matching resolution decision_id AND answer confirms acceptance; another resolution
shows who/when; open permits resending only the same detached signed decision in a fresh envelope
with a new rid/seq/salt and current timestamp. Never change the logical answer or re-sign it silently.
Stale epoch needs a verified higher grant and new rid/seq/salt, preserving the detached decision bytes.
An uncertain result never enables silent re-signing. Lock/background invalidates unsent review.
Render exact text/options/answer as plain text; expose bidi/invisible characters or refuse the item.
Full scroll-to-end and 0.8-second arming delay gate confirmation; no signing from push payloads.

For every host method, §8.6 check order and §14 refusals remain: malformed, not_member, revoked,
bad_signature, rid_conflict, already_done(status), stale_timestamp(host_ms), stale_sequence(high),
stale_epoch(epoch), forbidden_scope, busy, scope_changed and stopped as applicable.
Refusals never echo request text; clients use fixed local messages. No host_api added to refusal meta.
Unsupported host representation version uses signed/sealed HTTP 400 data
`{"host_api":0,"error":"unsupported_host_api"}`. V0 readers reject unknown view fields; protocol object
extensibility remains as specified upstream (including §8.3 ignoring unknown answer fields).
Unknown paths/invalid fields are malformed; a valid but unauthorized operation is forbidden_scope.
Refresh on open/reconnect/verified push hints, coalescing bursts and in-flight reads. Poll only while
that workspace screen is foreground: start at 15 seconds, back off to 30/60 seconds when unchanged,
offline or quota-limited; honor retry delays. Multiple event streams share one WorkspaceSession poller.
Each snapshot costs a seq, a rid record retained for 900 seconds and a v1 §5.3 quota charge (about
60 live records at the base cadence). Budget polling together with mutations against the actual v1
allowance/MAX_RECORDS; defer reads to preserve mutation headroom. Confirm those limits with P2;
a 30-minute clock-driven session under the imported limits must never get `busy` from its own polling.
No background correctness requirement, websocket or new streaming opcode. Last consumer cancellation
or leaving foreground stops periodic polling.

## 3. Pairing, identity, push and leave adapters

### Pairing routes

`POST R/workspaces/{ws}/pair/{offer}/{rid}` accepts raw epoch-0 ORB2; `GET` polls the same route.
Use the common chunk wrapper and `after` semantics above, no bearer required. No secret in the URL.
The route ws/offer/rid must equal header workspace/stream/rid. Limit envelopes to 64 KiB (§8.9).
V0 limiter: 60 posts/minute per workspace and 60/minute per client address; 120 GET polls/minute
per address. These provide at least 3× one honest phone's 5-second cadence, including initial traffic.
HTTP 429 `{"error":"rate_limited"}` carries integer delta-seconds `Retry-After` (the remaining interval rounded up; the fake's default is 5 and is configurable, clients must never assume 5); budgets use injected clock.
Send pair_status no faster than every 5 seconds, backing off to 10 seconds in cert_pending and
20/40/60 seconds on transport failure or 429; honor Retry-After as a minimum. GET once with each
POST, then at most once per 5 seconds while awaiting its answer; coalesce retries and never create
overlapping status requests. Stop on a terminal state/deadline. Test a full 10-minute cert_pending
run (including initial pair and resends) against both address and workspace budgets without 429.
These counts and error are invented; confirm routes, polling privacy and limits with P3 ([gap 22](gaps.md)).
Anyone knowing route ids may retrieve ciphertext; confidentiality and host authority remain K_pair/WSK.
Each pair_status is a new signed epoch-0 request, not a plaintext GET status command.
Pair request and pair_status meta and all five answer states remain exactly §8.3.
Requests sign with phone dk_sig and seal with K_pair derived from S; host signs responses with WSK.
Unknown offer/bad tag is silent; pairing_closed, cert_invalid, cert_expired, other_person, revoked,
bad_signature, malformed and stale_timestamp obey §8.3 budgets (five refusals/offer/minute).
Every epoch-0 answer/refusal includes wsk_pub. Transport acceptance is never pairing acceptance.

Parse the five-field fragment strictly. Canonical universal-link path is `/app/pair`; accept `/pair` alias.
Compatibility syntax chosen here: `orch://pair?relay=<percent-encoded-https-origin>#v2.…`.
Exactly one relay query parameter; reject absent/ambiguous origins, userinfo and additional fields.
Show reviewed origin for paste/QR. Never send the fragment or read clipboard without a user action.
Confirm compatibility syntax and native no-passkey join with upstream ([gaps 4–8](gaps.md)).
No credential_begin/finish, assert or Type operations in native P4; do not claim browser pairing parity.

### Grants, member lists, card and CK

`GET R/workspaces/{ws}/grants` returns `{"grants":[$signedWKGrant]}`.
Optional `epoch=<positive integer>` selects one; default returns all grants eligible for this device.
`GET R/workspaces/{ws}/members` returns `{"member_list":$signedMemberList}`.
`GET R/workspaces/{ws}/card` returns `{"card":$card}`.
All require authenticated current membership and non-revocation; recipient comes from the session.
No foreign-device selector. Missing data is 404 `not_found`, unauthorized is 403 `not_eligible`.
Protocol signature/shape errors retain §14 codes; these HTTP fetch wrappers have no additional signature.
WK grants and lists are WSK-signed; WK is sealed to dk_kx (§7.3). Lists carry `persons` and a `person_id` per member (P3-D6)
and the required `wk_commit = b64u(H("orch/v2/wk-commit|" || ws || u32(epoch) || WK))` (orch-29 Q10, decisions A16).
One WK per epoch, ever: the phone seals only at the head list's epoch, under a grant whose WK matches its `wk_commit`; a
mismatch or a missing list/grant blocks sending (no_key), never a fallback. Older epochs are read with any WSK-verified
grant, checked against `wk_commit` when a list for that epoch is held. Two verified lists at one epoch with different
`wk_commit` are the local alarm `wk_commit_conflict`, raised before a lower `list_seq` is refused as stale; it stops sealing at
that epoch until a verified list at a higher epoch arrives. The head's own `list_seq` with other content is `conflicting_snapshot`
(no sealing block). A read above the head, or before any verified list, is the local `future_epoch` (G2b D1–D4, orch-relay 491b500).
Grants are published with their list in one `PUT /v2/workspaces/{ws}/membership` (P3-D7, §19.2), never staged.
Verify signatures, identity binding and monotonic epoch/list/card counters before committing anything.
Routes and authorization are protocol-v2 §19.1/§19.2; the FakeRelay replays orch-relay's HTTP fixtures for them ([gap 24](gaps.md)).

`GET R/workspaces/{ws}/card-key?card_seq=N` returns exactly
`{"workspace_id":"$ws","device_id":"$sessionDevice","card_seq":N,"sealed":"$b64u"}`.
FakeHost creates and uploads this wrap only after a valid device certificate, in §8.3 step 6
alongside the WK grant, before join completes. No WK grant or CK wrap may exist for an uncertified
joining device, including during pending/cert_pending or after rejection, R1 alarm or primary expiry.
Seal CK to device dk_kx with existing purpose `card`, object=ws, epoch=card_seq, no extra (§5.3).
No new signing domain: the wrap is not sender-authenticated; card ck_commit binds the recovered key.
Phone verifies PK delegation against pinned owner, WSK pin/signature, sealed_hash, highest card_seq,
wrap target and CK commitment before opening the sealed card and displaying its name.
Never extend `approved`, use a bridge-supplied name as identity, or accept a lower card sequence.
Card race/missing wrap: refetch card, then that sequence's wrap; remain joining if unavailable.
Wrong CK fails locally; no plaintext-name fallback. Relay cannot prove a wrap's decryption succeeded.
Display hosted marker if delegation.client_hosted or nonempty hosted_by; use “hosted by (unknown)”
when the delegation requires the warning but supplies no name. Confirm CK delivery with P2/P3,
including retention and card-update races ([gap 29](gaps.md), D-6); fetch errors match grants above.

After verifying the card, require byte-equal `card.relay_url == reviewed link origin` in §7.1 form.
Require the verified member list to contain this device_id with scopes exactly equal to approved.scopes,
list epoch >= approved.epoch (all >= 1), the installed grant epoch equal to that list epoch with its WK matching the list's
`wk_commit` (`grant_commit` otherwise), and record the verified list as the head before installing any key.
A mismatch fails join; no partial workspace install or silent origin change is permitted.

`GET R/devices/{device}/revocation` returns `{"record":$signedRevocation}`;
absence is 404 `not_found`. This proposed gap-24 route takes no session: the record is a public PK-signed object and a
revoked device has no session. Decided (owner, 10 October 2026): a revoked device gets no relay session. Login for a revoked
device answers 403 `revoked` (after its signature verified, so strangers learn nothing), publishing a revocation ends the
device's sessions, and the relay drops its grants, card-key wraps and queued requests. The client fetches its own record
on that 403 (or any `revoked`) without a session; confirm with P3 ([gap 24](gaps.md)). Verify the exact §6.2 record with `Revocation.verify`,
the pinned PK and this device_id before identity-wide wipe. An unsigned relay 403 (including `revoked`)
or a WSK-signed bridge `revoked` only triggers this fetch; neither authorizes wiping. If unavailable,
stop affected sends and show unverified status, retaining local state. Verified host `not_member`
means removed from that workspace: stop sending and offer local wipe, not identity-wide revocation.

### Push registration

`POST R/push/register` body:
`{"workspace_id":"$ws","registration_id":"$hex16","env":"sandbox",
"topic":"io.severin.orch","token":"$b64uAPNsToken"}`.
`env` is `sandbox|production|demo`; demo token is random synthetic bytes, never an APNs token.
Response is `{"registration_id":"$id","registered":true}`.
TODO(orch-4e): push registration is not in protocol-v2 §19; the FakeRelay no longer stubs it with 501 (it answers 404 `not_found`) until upstream defines the route.
Authenticated session supplies device_id; register requires current membership and a valid certificate.
Same registration id/body is idempotent; replacement token uses a new registration_id.
Store per device/workspace/env/topic, retiring the previous registration for that tuple.
`POST R/push/unregister` has `{"workspace_id":"$ws","registration_id":"$id"}`;
response is `{"registration_id":"$id","registered":false}`, including if already absent.
`registration_id: null` in request and response means remove all of this device's registrations in
that workspace; membership is unchanged. This is the bounded network cleanup used by local Leave.
Unregister authenticates ownership of the registration and allows a removed but non-revoked device.
Never delete another workspace's registration even though APNs token bytes are shared.
No detached signature/seal: bearer auth established with dk_sig; HTTPS protects token privacy.
Malformed/env/topic mismatch → 400 malformed; another device → 403 not_for_this_device;
revoked → 403 revoked; registration without membership → 403 not_eligible.
These routes, token encoding, idempotency and auth require P3 agreement ([gaps 14–16](gaps.md)).

Install K_push(epoch), pinned WSK and card name in the push group before registering; ask permission
only after first successful join. Xcode uses sandbox, TestFlight production even with a dev relay.
§9 payload stays unchanged: WSK signature inside SALTED-AEAD under derived K_push, max 3,072 bytes.
FakeHost assigns ts_ms = max(clock.now, prior entity timestamp + 1); confirm [gap 17](gaps.md).
Demo feeds sealed bytes into PushProcessor then a local notification, never APNs/NSE simulation evidence.
Native rejection/timeout fallback is app-authored generic text with no route; do not promise suppression.
No collapse id in P4; question.closed replaces by scoped entity id. `join` is verified but not displayed.
Tap reverifies, fetches authoritative state, then acts; badge is last reconciled unanswered count.
Real APNs envelope remains unresolved upstream ([gaps 10–19](gaps.md)); v0 invents no provider headers.

### Leave is not member_remove or revocation

Local Leave succeeds independently of these network calls. First persist removal generation/tombstone
in app index and both groups; disable routes/targets, cancel and drain writers, then erase workspace keys,
plaintext, previews, jobs, notifications and SQLite sidecars/container. Recheck generations under locks.
Keep tombstones outside deleted containers, resume after crashes and run a second notification cleanup.
Only after local wipe attempt network cleanup, at most two attempts within 10 seconds total (v0 choice).
A still-valid per-relay session may be held in memory for that bounded attempt; never retain WK or deleted
workspace secrets, mint a cleanup credential, or delay erasure to finish an authentication handshake.
With no usable session, report “Finish on your Mac”; persistent cleanup status contains no credentials.
Keep device keys/cert after last leave (D-1); Reset erases them. Offline leave never queues signatures.

After wipe, call unregisterPush with that workspace_id and registration_id (or null for all).
A failed call returns separate cleanup status, never rolls back wipe. There is no leave transport route.
Confirm post-wipe unregister authorization with P3 ([gaps 20–21](gaps.md)); no cleanup credential is invented.

An authorized remaining Operate device/primary can issue exact §6.3
`{"op":"member_remove","device_id":"$id"}` via its own dk_sig/K_bridge, response WSK/K_bridge.
No host_api added. Host rotates: one atomic membership publication of the list and every remaining grant
(protocol-v2 P3-D7); the relay deletes departed devices' mailboxes, grants, card-key wraps and subscriptions. Its success projection may be `{"host_api":0,"removed":true}` (provisional).
Look/Decide phones cannot self-remove through this op; forbidden_scope is correct, even for themselves.
A PK-signed revocation (§6.2) instead kills the identity across all workspaces: verify then wipe all,
invalidate cert/device keys and require new keys. Phone is never primary in P4 (D-2).
Missing expected custody fails closed with dependent cleanup; temporary lock is not key loss.
Clean orphan keychain items without a realm index at launch. Confirm op outcome with P2 ([gap 25](gaps.md)).

## 4. Drop adapter and Demo fixtures

DropService owns typed §10 objects and verified downloads, using RelayTransport bytes, not snapshot labels.
Use protocol §10.6 `PUT /drop/{id}/versions` unchanged: version is in the descriptor, not the path.
Only `POST R/drop/list`, `GET R/drop/{id}/versions/{version}/{descriptor|wraps|blob}` and JSON packaging
are provisional v0. Confirm packaging with P3 ([gap 25](gaps.md)).
Put JSON: `{"descriptor":$signedDropObject,"wraps":[$wrap],"blob":"$b64uORD2"}`.
List request: `{"workspace_id":"$ws","direction":"received"}` (`received|sending`).
List reply: `{"objects":[{"descriptor":$signedDropObject,"wraps":[$wrap]}]}`.
Get descriptor/wraps replies use `{"descriptor":$signedDropObject}` / `{"wraps":[],"claimed_by":null}`;
blob response is raw ORD2 with version header. Put reply is `{"version":1}`.
TODO(orch-4e): Drop routes are not in protocol-v2 §19 yet. Open question: do they move under `/v2` (the phone and FakeRelay put `list` and `GET versions/...` there now, while `PUT /drop/{id}/versions` and `POST /drop/{id}/claim` keep their §10.6/§10.5 spelling) and what is the final field set.
Author dk_sig/WSK signs the existing descriptor; fresh DEK seals content/meta; existing §10.3 wraps only.
No extra signature on wrappers. Verify author authorization, content_hash, dek_commit, chain and latest version.
Every PUT requires decimal If-Match without leading zeros: missing/malformed is HTTP 428
`precondition_required`; a CAS/parent/version mismatch is HTTP 409 `version_conflict` with `current`.
Version-1 rule proposed as an explicit §10.6 amendment request: an absent object has current=0,
requires `If-Match: 0`, version=1 and parent_hash=null. This extension needs upstream approval.
Later versions obey §10.6 CAS/parent_hash unchanged. A lost successful PUT followed by a stale
If-Match returns 409; fetch and compare the committed descriptor/blob to reconcile it.
Authenticated read/write scope, recipients and expiry gate access; bad eligibility is not_eligible.
Host-only claim uses existing `POST /drop/{id}/claim` (§10.5), never a phone-generated WSK signature.
Explicit inbox claim uses bridge meta `{"op":"drop_claim","object_id":"$id","version":1}` with empty data and **operate** scope. It returns status 200 and `{}` after the host's WSK-signed §10.5 claim succeeds. Phones never sign claims. Download refuses an unclaimed inbox (`unavailableKey`); wraps read-back includes `claimed_by` (workspace ID or null).
Old objects use exact `drop_rewrap` (§7.5), requiring look scope. It refuses an unclaimed inbox; an already-claimed inbox receives a current-WK wrap through ordinary rewrap publication, preserving claim ownership. No historical WK grant is issued to a new device.
Send/recovery require signed current membership with operate scope and matching epoch grants. An uncommitted stale-epoch upload is resealed with a fresh DEK only after read-back confirms an empty slot. Recovery returns per-upload outcomes and persists terminal conflicts/rejections; retry/discard are explicit.
`downloadVerified` exposes authenticated name, MIME, plaintext size and transcript with the plaintext URL through `DropDownload`; keys remain private.
Native compose chooses destination first, maximum five attachments/25 MiB total plaintext, default seven-day
expiry. Notes/URLs are immutable file content with suitable MIME; URLs are text, never fetched.
Preview only after full authenticated decryption. Share extension stages; foreground app signs/uploads.

Seed after fake authority creation, using real signatures, seals and fresh keys, relative to injected now:

| Workspace | Card identity and contents |
|---|---|
| Laptop | name Laptop, client_hosted=false, hosted_by=null; epoch 1, card_seq/list_seq 1 |
| Client VM | name Client VM, client_hosted=true, hosted_by="Example Client"; separate WSK/WXK/WK/CK |

Both belong to one fresh Demo person; each has its own valid PK delegation/card and member list.
Starting lists include Demo Mac (primary); joining adds Demo iPhone at the current epoch, no old grants.
Seed logical names map to generated hex ids in Demo storage; tests can derive deterministic fixture ids.
Laptop: MOB-1 pairing review, MOB-2 interrupted decision recovery, FAC-1 “Factory: mobile readiness”
(kind factory_epic), with MOB-1/MOB-2 referencing it. Client VM: VM-1 “Approve staging deployment”.
Question Q1 on MOB-1: “Enable mobile access?” options Approve/Reject, created now−30 min.
Question Q2 on MOB-2: concatenate “Review recovery step N: verify the stored decision before retrying.\n”
for N=1…80; options Continue/Stop, created now−20 min. This must require scrolling at all text sizes.
Question Q3 on VM-1: “Deploy invoice \u202Etxt.exe\u202C?” with actual U+202E/U+202C scalars;
options Deploy/Reject, created now−10 min. Hash original scalars; visibly expose controls or refuse review.
Include one closed question with a valid Demo Mac decision for reconciliation/closure UI.
Drop: Laptop has `readme.txt`, empty `empty.txt`, short UTF-8 note and literal `https://example.invalid/`;
Client VM has `deployment.txt` addressed via WXK then claimed, plus a two-version “Runbook” document.
Each file expires now+7 days; each version gets fresh DEK, descriptor and appropriate wraps.
Include a Sending entry and an old-epoch object in the rotation scenario; no real customer data/URLs.

## 5. Fake actors, enforcement and evidence

FakeRelay actor owns directory certs/revocations, cards, member lists, grants/CK wraps, sessions/challenges,
mailboxes with TTL, rate budgets, push registrations, Drop blobs/descriptors/wraps/claims and queues.
It has no WK, CK, S, DEK or authority private keys; route authorization never decrypts bridge content.
It checks §8.9 header/session membership, §12.2 login, §19.2 atomic membership publication and §10 atomic CAS/claims.
FakeHost actor owns WSK/WXK, epoch keys/history, CK per card, offers/S/sas_nonce, device label registry,
seq windows/rid records, snapshots, durable mutation receipts and per-entity push timestamp counters.
It implements §8.6 in order, including silence before tag, budgets, replay/quota semantics and rotation.
Offer lifetime is 10 minutes; keep used offer records 24 hours; rid records last received_at+900 seconds.
FakePrimary actor owns synthetic PK/PVK and primary device keys, seen requests, one open request/workspace,
stored challenges and signed/rejected state. It enforces §8.4 order and signs exactly stored keys once.
It logs in with its own device key and uses the §19.3 D(p) routes through `RelayClient` (cert-requests poll,
challenge, PK-signed `cert_rejection`); FakeRelay runs the P3-D11 state machine (`CertQueue`, held to the
`p3` vectors) and the host posts/reads requests over HTTP with its workspace session.
Host-is-primary uses the same certification authority logic; a client-hosted host never receives PK.
Separate labelled Demo host and Demo primary panels default Reject; Approve requires “I compared the codes”.
No scenario may automatically set that confirmation on behalf of a human in the shipped Demo.
T0 may invoke explicit panel commands after asserting comparison state; this is a test driver, not auto-approval.

P2 vector gate: exercise all cases/chains in each named group, not just round trips with our own encoder:

| Component | Required suite-2 vector groups |
|---|---|
| Shared OrchProtocol | encodings, sign, hkdf, salted_aead, seal, seal_open, certs, revocations |
| FakeHost | bridge.seal, bridge.host_cases, bridge.sas; wk_grants.cases; member_lists; push.cases; decisions, question_hash, revocation_op |
| FakePrimary | cert_request.cases, open_cases, challenge, cert_code, signed_cert, sign_again, attack_challenge |
| FakeRelay | card.cases, member_lists, wk_grants.cases, relay_auth.cases, drop.claims, drop.documents |
| Phone through fakes | bridge.links, bridge.pair_answers, bridge.device_cases, bridge.seal; card.cases, card.hosted_marker, card.card_key_wrap_to_phone; wk_grants.cases; decisions, question_hash, relay_auth.cases (signed bytes), member_lists, push.cases |
| DropService/fake storage | drop.blob, empty_blob, meta_sealed, wraps, wrap_negative, descriptor_cases, documents, document_chains, claims |

Leaf fixtures (e.g. challenge/blob) require byte assertions; cases/chains require result AND resulting state.
FakeHost output verification additionally uses card/grant/member-list vectors; FakePrimary verifies card delegation.
Phone and host must pass cert_pending/R1, stale_epoch, card and Drop claim round trips independently of Demo UI.
Publish vectors with upstream commit and SHA-256 recorded in test resources when implemented (A14).
V2 §16 lacks host new_ticket/member_remove/drop_rewrap and full quota vectors: add v0 T0 tests, never
label those upstream coverage. Carry v1 quota requirements forward; lack of a v2 vector is not permission to omit.

Inject `any Clock<Duration>` for scheduling, a wall-millisecond provider for §15, an Entropy source and
FaultPolicy into all actors/session/coordinator. Use the clock existential only via `sleep(for:)`;
TestClock is in-house (no swift-clocks dependency, A14) and advances scheduling and wall time
deterministically; offset remains separate.
Production Demo uses secure entropy for authority/device/seal material; deterministic entropy is test-target only.
FaultPolicy selects named boundaries: before queue, after host commit/before response, before grant publication,
reorder/duplicate/drop chunk, disconnect, corrupt ciphertext, wrong echo or adversarial cert challenge.
It may corrupt transport/test inputs; it cannot bypass verifiers. No real sleeps/random flakiness in T0.
UI tests may scale time ×60. Release rejects --seed/--fault/--scenario; curated Demo controls select safe fixtures.

C1 is a capability boundary: FakePrimary construction requires a DemoCapability minted only by
realm bootstrap, with no public initializer. It binds a Demo StoreLayout/WorkspaceIndex and in-process
relay to Realm.demo; RealmContext is a proposed wrapper around that existing OrchCustody Realm.
Do not introduce a parallel DemoStore abstraction. A public bootstrap may create a Demo context only;
callers cannot supply a live store, custody realm or external transport to manufacture the capability.
All stores/routes/jobs/keychain/notifications carry `(realm, ws, generation)`; stale generations cannot publish.
Only relay.demo.invalid is reachable in Demo, and only in-process; reject external origins before any request.
Fresh authority keys per install/reset live in protected, backup-excluded Demo storage and are erased on exit.
No vector scalars/Python reference in shipped targets, live-key lookup, imported recovery material or cross-realm certs.
Device dk_sig/dk_kx are distinct per realm, stored under realm-tagged SecretID values by
DeviceKeyCustody.create/load(realm:); never reuse live keys or device_id in Demo. Device Demo keys
still use Secure Enclave; this does not make synthetic certification security evidence.
Reset Demo deletes only Realm.demo custody, certificates and stores; live identity remains intact.
Release negative tests must prove transport isolation, live-key lookup denial, cert reuse denial and reset scope.

## 6. Pairing coordinator and scenarios

Persist encrypted pending state before send: realm/generation, reviewed origin, ws/offer, S custody reference,
link pins, own key references, optional existing cert/person, label, seq/rid and serialized request, clock offset,
start/last-progress times, validated WSK/PK, pinned sas_nonce/pk_pub, current state and first valid
challenge/expiry when present.
Never persist a rendered code as authority: recompute from verified inputs. Never log S/full fragment.
After restart revalidate expiry, custody and generation, clear comparison UI, then poll the stored request.

| Coordinator state / U5 screen | Verified transition and timing |
|---|---|
| parsing / parse | Strict link+realm validation → connecting; existing cert of another person → otherPerson without sending |
| connecting / connecting | Send pair, GET mailbox at the §3 bounded cadence; pending verified with own key echo → comparingHost |
| comparingHost / compare with host | Show SAS only after pin/signature/tag/time/echo checks; poll new pair_status every 5 s with §3 backoff |
| waitingPrimary / cert pending | cert_pending clears SAS immediately; null challenge shows “Open orch on <primary>” and countdown |
| comparingPrimary / compare with primary | Valid PK challenge for own keys shows only cert_code; expires_ms hides it immediately |
| joining / joining | approved verifies PK pin, own-key cert/scopes → login, grant, list, card+CK verification and atomic workspace install |
| ready / ready | Verified join committed; erase pending secret/transcripts, publish push keys, then offer notification permission |
| alarm / full-screen alarm | Wrong echoed keys, R1 challenge, regression or pin substitution → persist terminal alarm, stop and hide all codes; use the distinct instructions below |
| rejected, expired, failed / terminal explanation | Verified rejected/expired, validation failure or timeout; no ready workspace |
| cancelled / dismissed | Local cancellation from any pre-ready state; erase pending data; no implied host revocation |

Pin sas_nonce on the first valid pending and pk_pub on its first authenticated occurrence (checking
the link pk_pin); neither may change. Pin the first valid challenge, including request_id,
primary_nonce, own keys and expiry; an identical repeat is allowed, any substitution alarms.
State only advances: pending after cert_pending, cert_pending after approved, or null challenge after
a pinned challenge is a regression and alarms; never replace the code or move backwards. Approved
must retain pinned pk_pub; its certificate keys must equal own keys and the pinned challenge's keys
when a challenge was shown. Persist pins/state before exposing comparison UI, including across restart.
Alarm screens are terminal and survive restart: echoWrongKey says “Reject on your Mac (host)”.
r1Attack says “Reject on <primary_label>; do not confirm any code there; this host may be compromised”.
Use a safe local primary label or “your primary device”; neither alarm shows SAS or cert_code.
Other substitution/regression alarms direct the user to abandon and reject outstanding host/primary prompts.

No initial authenticated answer within 60 s, or pairing_closed → “this link was used by someone else:
reject it on your Mac” (§8.3). Offer expires on host at 10 min; link does not encode a trusted deadline.
Local pre-approval cap is 10 min from start and ends at host approval; it never cuts cert_pending short.
cert_pending has its own 10 min from host entry, not link parse.
Null challenge countdown uses first observed cert_pending time as an estimate; host expiry is authoritative.
Once challenge exists its signed expires_ms is the exact deadline; never extend it on polling/restart.
Joining waits at most 60 s before showing retryable connection failure; transport loss is not rejection.
On cancel/expiry erase S/K_pair, pending envelopes, challenges, codes and uncommitted grants/CK/session refs.
Delete newly allocated uncommitted device keys only if no other workspace/pairing uses them; preserve existing
identity/cert per D-1. Cancel cannot un-use the offer or retract a certificate already issued; explain Mac cleanup.
A late response cannot recreate a cancelled generation. Never retain a pending secret for indefinite retry.

| Scenario name | Required observable outcome |
|---|---|
| firstTime | host comparison → cert_pending → primary comparison → verified grant/card → ready |
| existingCert | host comparison then joining; no primary prompt, certificate keys still checked |
| hostIsPrimary | host comparison then local primary signing; no remote cert-code screen |
| primaryOffline | null challenge, countdown, expired after host's 10 min; no WK grant or CK wrap |
| linkUsed | different consumer → pairing_closed; same keys can recover pending after response loss |
| r1Attack | primary challenge names attacker's keys; full-screen alarm and no cert code |
| echoWrongKey | pending echoes foreign signing or exchange key; host-rejection alarm before SAS |
| otherPerson | existing foreign cert rejected locally; forged bypass refused by host/directory |
| rejectOnHost | rejected, no certificate/grant/member addition |
| rejectOnPrimary | request closed, never signs; PK-signed rejection relayed by the host; phone verifies it and shows `denied` |
| revokeAfter | verify PK revocation, rotate, remove grants/subscriptions, wipe every dependent workspace |
| staleEpochRotation | stale epoch refusal, higher grant fetch, new rid/seq; preserve logical decision |
| already_answered | second valid answer shows by_device_label/at_ms; no accepted haptic |
| question_changed | hash mismatch forces authoritative reload and a fresh immutable review |
| lostResponse | fault after commit; restart resends stored envelope/same rid first; expired/unknown replay falls back to question fetch; no duplicate side effect |

Primary rejection is the P3-D11/P3-D28 `cert_rejection` (PK-signed, bound to the attempt: `offer_id`, `attempt`,
`device_id`, `dk_hash`, `expires_ms`). The host relays it in the long `rejected` form `{state, wsk_pub, pk_pub, rejection}`
(protocol-v2 §8.3, orch-relay 04da0e7); the short form `{state, wsk_pub}` is its own refusal. The phone shows "Denied by the
owner" (`pair.deniedByOwner`, attributed to the pinned owner key) only after every §8.3 check; anything else is the unattributed
"The pairing was refused", and a rejection naming a foreign device raises the alarm. The phone joining timeout stays provisional. UI clock scaling changes no check order.

## 7. Implementation slices and evidence gates

M3 dependencies are implemented, not stubs: integrate `feat/m3-custody` (mobile-m3a) and
`feat/m3-store` (mobile-m3b) before dependent client work. Reuse OrchCustody `Realm`,
`DeviceKeyCustody`, `DeviceIdentity`, `DefaultCustody`, `SecretVault`/`RealmVault` and `SecretID`;
DeviceIdentity exposes publicKeys publicly and signing/agreement handles only within the package.
Use OrchStore `StoreLayout`, `WorkspaceIndex`, `WorkspaceContainer`, `SQLiteDatabase`, `Migration`,
`TombstoneCoordination`, `LocalWipe` and `WipeHooks`. Convert ID16 to canonical hex and Realm to
rawValue only at existing string-based store boundaries. WorkspaceSession adds durable review,
pending-envelope/decision and sequence migrations; the current request-id/epoch helpers alone do
not provide mutation recovery. Use SQLiteDatabase's synchronous transaction closures (no await).
Wire custody, cancellation/draining and notification cleanup through WipeHooks and resumePendingWipes;
extend these implementations as needed rather than create competing store/custody/wipe layers.

Run T0 with `swift test --package-path OrchKit`; names below are proposed tests, not claims of passes.
Protocol vectors belong in OrchProtocolTests; client/fake integration tests use the real byte path.
Static previews do not qualify. The slices below separate dependencies and review scope.

- **Slice 0 — pure protocol completion.** ORB2 envelope codec/seal/open, card/delegation,
  member-list, WK-grant and cert_request/challenge validation, relay-auth signed bytes and Drop codecs.
  No transport, coordinator or host pipeline in this slice. Vector gates: bridge.seal/device_cases,
  card.cases/hosted_marker/card_key_wrap_to_phone, member_lists, wk_grants.cases, cert_request.*,
  relay_auth.cases, drop.* and decisions/question_hash, alongside existing shared primitive vectors.
  Leaf and chain assertions follow §5; inventory implemented code first and fill only remaining gaps.
- **Slice 1 — transport and fake authority bootstrap.** Depends on slice 0 and M3 integration.
  Versioned wire codecs, RealmContext/DemoCapability bootstrap, fake directory/session/mailboxes,
  rate/quota accounting and injected time/entropy/faults.
  T0: testRelayAuthVectors, testRelayHeaderSessionBinding, testAdapterVersionRejected,
  testMemberListRequiresGrantsBeforePublish, testDemoRejectsExternalOriginBeforeRequest,
  testDemoCertificateCannotEnterLiveRealm, testHeaderNamesCaseInsensitive,
  testZeroGrantEpochRejected, testPollCursorUInt64.
- **Slice 2a — host bridge pipeline and WorkspaceSession.** FakeHost §8.6 ordered checks and
  phone §8.8 response validation, durable seq/rid/envelopes, replay/quota/timestamp/epoch behavior.
  Gate on all bridge.host_cases and bridge.device_cases independently, including replay before time
  checks, already_done(unknown), exact stored-envelope resend, chunk binding and stale generations.
  This supplies the host pipeline before pairing/UI integration; it is separate from pure codecs.
- **Slice 2b — pairing and verified identity.** Depends on 1/2a. FakeHost/FakePrimary pairing,
  PairingCoordinator and grant/list/card/CK installation.
  T0: testPairAnswerVectors, testPrimaryCertRequestVectors, testPairingScenarioMatrix,
  testR1AlarmHidesBothCodes, testAlarmInstructionsPersistAcrossRestart,
  testPairingPinsAndMonotonicChains (nonce/PK/challenge substitution and all regressions),
  testApprovedCertMatchesPinnedChallenge, testCertPendingTenMinutesWithinRateLimits,
  testPairingHonorsRetryAfter, testCancelErasesPendingSecrets, testPairingResumeAtExpiry,
  testCardWrongCKRejected, testHostedMarkerCannotBeHidden, testApprovedNotExtendedWithCK,
  testCardOriginMatchesLink, testJoinRequiresOwnMemberScopesAndEpoch.
  testNoGrantOrCardWrapBeforeValidCertificate inspects FakeRelay storage, not just phone state:
  no device WK grant or CK wrap during pending/cert_pending, after rejectOnHost/rejectOnPrimary,
  primaryOffline expiry or r1Attack; valid certification publishes both only in §8.3 step 6.
- **Slice 3 — host views and durable mutations.** BridgeWorkspaceAPI, immutable QuestionReview,
  WorkspaceSession signing, pendingDecisions, seeded questions/tickets/Factory, event-driven refresh,
  quota-aware polling, decisions and new_ticket idempotency.
  T0: testSnapshotRejectsUnknownFields, testSnapshotNeverSuppliesIdentityName,
  testReviewRereadsAndRecomputesHash, testUIOnlyUsesUnsignedReviewAPI,
  testBidiReviewPreservesHash, testLongReviewRequiresScrollAndArming, testDecisionVectors,
  testLostResponseReplaysStoredEnvelope, testExpiredOrUnknownRidReconcilesByQuestion,
  testPendingDecisionsSurviveRestart, testStaleEpochPreservesSignedDecision,
  testQuestionChangedRequiresReview, testAlreadyAnsweredShowsActor, testNewTicketRetryCreatesOnce,
  testCreationConflictIsSealed409, testForegroundPollingThirtyMinutesWithinQuota,
  testEventsReturnsIndependentStreamsWithSharedPoller.
- **Slice 4 — push and removal races.** Registration/unregister adapters, real sealed Demo push
  processing, signed revocation fetch and local wipe-first Leave with bounded cleanup.
  Change PushProcessor.ReplayState from a global maxShownTs to a per-workspace high-water mark
  (scoped by realm at storage boundary). Timestamp floors and pruning use only that workspace's
  maxShownTs; keep per-entity lastShown keyed by workspace/id. Persist and clear replay state with
  its workspace/generation. Do not copy a legacy global watermark into every workspace; migrate
  from retained per-workspace entries, with no-history behavior for an empty workspace.
  T0: testPushVectors, testPushReplayWatermarkIsPerWorkspace (a high timestamp in A cannot suppress
  or prune B), testPushReplayMigrationAndWorkspaceWipe, testPushRegistrationEnvironmentAndOwner,
  testClosureTimestampIncreases, testUnregisterNullIsWorkspaceScoped,
  testLeaveOfflineWipesBeforeCleanup, testDecideScopeCannotMemberRemove,
  testUnsigned403NeverWipes, testHostRevokedRequiresPKRecord, testNotMemberIsWorkspaceOnly,
  testRevocationInvalidatesAllWorkspaces, testLateResponseCannotResurrectGeneration,
  testWipeCrashAfterEachPhase, testConcurrentShareAndPushWritersObserveTombstone.
  No APNs/provider or primary-phone implementation is implied by these tests.
- **Slice 5 — DropService and fixtures.** Separate from push/removal; depends on protocol, transport
  and M3. Typed objects, verified downloads, document chains, CAS, claim/rewrap and Drop-only Files UI.
  T0: testDropVectorsAndDocumentChains, testDropPutProtocolRoute,
  testDropPutRequiresIfMatch428, testDropCreateIfMatchZeroProposal,
  testDropCASConflict409AndLostResponse, testNewMemberRewrapWithoutHistoricalGrant.
  Version-1 amendment and packaging remain subject to upstream agreement (§4).

Create a separate `OrchC1PublicAPITests` target using ordinary imports and public bootstrap/APIs only:
no @testable, package/internal signers or SoftwareSigner(testScalar:), and no shipped fixture keys.
Run it in Release with `swift test --package-path OrchKit -c release --filter OrchC1PublicAPITests`.
The Release test build must also compile: exclude Debug-only vector targets/helpers from that build
(or isolate the public-API suite in a test package); --filter alone does not exclude their compilation.
Prove transport isolation and cross-realm certificate denial there; Debug vector T0s remain separate.
`testDemoCannotLookupLiveKeys` and `testDemoResetScope` are hosted app tests with real keychain
entitlements, also run in Release; an in-memory SwiftPM backend is supplementary evidence only.
T0 does not establish real NSE invocation, Secure Enclave custody, passcode-removal behavior or APNs
delivery: retain the pinned-runtime/device evidence gates in decisions T2/T5.

### Slice 5 implementation notes

`DropService` is workspace-scoped and constructed with a `WorkspaceSession`, its verified card and
owner-verified certificates for other device authors. Unknown authors fail closed (v0 has no certificate
lookup route). `list`, `send`, `download`, `claim`, `resumeUploads` and `importShareJob` expose no signing
or agreement handles. Device PUT requires `operate`; read/rewrap requires `look`. A member send includes
WXK, sender-device and current-WK wraps. Inbox claim requests use the operate-scoped host `drop_claim` op to
produce the §10.5 WSK-signed claim; no new phone signing authority or protocol claim route is introduced.
See **Slice 5 additions** in gaps.md for quotas, persistence and authorization limitations.
