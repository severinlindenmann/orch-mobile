# Claude challenge of host API v0

Reviewed 10 October 2026: [host-api-v0.md](host-api-v0.md) against [decisions](decisions.md), [gaps](gaps.md),
[challenge-codex](challenge-codex.md), protocol v2 (§4–§15) and `vectors_v2.json` suite 2 (group names checked).
Swift fit checked against `mobile-m2/OrchKit/Sources/OrchProtocol` at 0bc73c8 (`ID16`, `package Signer`,
`package Decisions.makeOp`, `SignedKind`) and `Package.swift` (OrchFakeHost depends on OrchClient).
This is a design review; nothing here was executed. v1 (§5.3 quotas, §3.5 `http` meta) was not available.

## Accepted as written

- §1 version boundary: `host_api` never enters certs, grants, cards, pairing meta, decisions or §14 refusals;
  relay HTTP errors and empty polls never count as verified host answers. Correct and important.
- §2 `http` allow-list (GET only, no headers, fixed paths, key regex, no escapes) and "no detached signature on
  projections; labels are never identity". Scope mapping look/decide/operate is a reasonable P2 proposal.
- §2 decision handling: persist before send, reconcile before retry, never re-sign, `stale_epoch` resealed with
  new rid/seq/salt preserving the detached decision bytes (§8.5, §13). Matches U7/U8 and challenge U7/U8.
- §3 card/CK: CK sealed with purpose `card`, object=ws, epoch=card_seq (§5.3), `ck_commit` before decrypt,
  marker from `delegation.client_hosted`, `approved` not extended (D-6). Vector `card.card_key_wrap_to_phone` fits.
- §3 leave ≠ `member_remove` ≠ revocation; Look/Decide self-removal is `forbidden_scope` (§6.3). Wipe-first order.
- §5 FakeRelay holds no WK/CK/S/DEK; FaultPolicy cannot bypass verifiers; no auto-approval in shipped Demo.
- Swift 6: `RelayTransport: Sendable` with async requirements is satisfiable by actors and by a future
  URLSession struct; `WireReply`/`Data`/`[String:String]` are Sendable. No concurrency blocker found.

## Issues

**1. §1 Swift boundary, `decide(_ SubmittedDecision)` — blocker.**
Objection: SubmittedDecision "contains ... the exact §13 signed decision op", so the caller signs before calling
WorkspaceAPI. Screens would need custody, contradicting "screens receive only WorkspaceAPI…". It also cannot be
built from the app target: `Signer` and `Decisions.makeOp` are `package` (only OrchKit modules can call them).
Consequence: either custody leaks into the UI layer or the signature as written does not compile from the app.
Change: `func review(questionID: ID16) async throws -> QuestionReview` (authoritative fetch, hash recomputed,
immutable, carries generation) and `func decide(_ review: QuestionReview, optionID: String) async throws ->
DecisionOutcome`; the WorkspaceSession signs, persists and sends. Add `func pendingDecisions() async ->
[DecisionStatus]` so an `uncertain` outcome is observable after restart.

**2. §3 pairing limiter vs §6 cadence — should.**
Objection: one honest phone polling `pair_status` every 2 s posts 30/min, exactly the per-workspace cap, plus the
initial `pair` and any resend; each post needs ≥1 GET, so 60 GETs/min per address has no headroom. cert_pending
lasts up to 10 min. Consequence: firstTime/primaryOffline hit 429 deterministically. Change: poll `pair_status`
at 5 s (backoff to 10 s in cert_pending), GET with the post; budgets ≥ 3× the honest cadence; T0 asserts the full
10-minute cert_pending run stays under budget.

**3. §6 alarm text, R1 vs echoWrongKey — should.**
Objection: both alarms say "reject on Mac". In R1 (§8.4) the misbehaving party is the *host*, and the primary is
showing a code for the attacker's key; rejecting on the host is meaningless, especially when client-hosted.
Change: echoWrongKey → "Reject on your Mac (host)"; r1Attack → "Reject on <primary_label>; do not confirm any
code there; this host may be compromised". Both terminal and persisted across restart.

**4. §6 coordinator state machine is not monotonic — should.**
Objection: the table lists forward transitions only. Not specified: regressions (`pending` after `cert_pending`,
`cert_pending` after `approved`), a changed `sas_nonce` in a repeated `pending`, a *different* valid challenge
(other `request_id`/`primary_nonce`) replacing one already shown, or `pk_pub` changing between `cert_pending`
and `approved`. Consequence: the host can swap the displayed code mid-comparison (R8 confusion) or downgrade state.
Change: pin `sas_nonce`, `pk_pub` and the first valid challenge; regression or substitution → alarm; `approved.cert`
keys must equal the pinned challenge's keys when a challenge was shown. Add these as pair_answers-style T0 chains.

**5. §3/§6 no-WK-before-cert invariant, CK wrap timing — should.**
Objection: "FakeHost creates and uploads this [CK] wrap ... before join completes" allows sealing card contents to
an uncertified key (e.g. during cert_pending, or for a link consumer who is later rejected). §8.3 step 5 forbids
WK; CK has the same exposure class. `testNoGrantBeforeValidCertificate` checks only grants and only at the phone.
Change: upload CK wrap only in §8.3 step 6 after a valid certificate (with the grant). T0 inspects FakeRelay storage:
no `wk_grant` and no `card` wrap for the device exists in pending/cert_pending, after rejectOnHost, rejectOnPrimary,
primaryOffline expiry and r1Attack.

**6. §3 joining, relay origin not bound to the card — should.**
Objection: the phone talks to the reviewed link origin, but nothing compares it to the signed `card.relay_url`
(§7.1). Change: after card verification require byte-equal `relay_url == reviewed origin` (§7.1 form), else fail
join; also require the verified member list to contain own device_id with `scopes == approved.scopes`, epoch ≥
`approved.epoch`, and grant epoch == list epoch.

**7. §3 revocation has no signed source — should.**
Objection: revokeAfter requires "verify PK revocation", but RelayTransport has no route returning the signed §6.2
record; relay HTTP 403 `revoked` is unsigned and relay-forgeable. Consequence: an implementer wipes every
workspace on an unsigned 403 (relay-triggered mass wipe), or the scenario cannot be built. Change: add
`revocation(deviceID:)` returning the signed record (gap 24 family); unsigned 403 and host-signed bridge `revoked`
only trigger that fetch; wipe-all only after `Revocation.verify` with the pinned PK. Define verified `not_member`
as "removed from this workspace" (stop sending, offer local wipe), distinct from revocation.

**8. §2 decision reconciliation ignores rid replay — should.**
Objection: the protocol already answers a lost response: resending the *stored envelope* (same rid) gets v1 §5.3's
recorded answer while the rid record lives (received_at + 900 s; §8.6 step 5 precedes the time check). v0 jumps to
an invented `/v2/questions` fetch and treats "already_answered even for a retry" as normal. Change: first resend
the identical envelope; on `already_done(unknown)`, unknown rid with stale_timestamp, or after 900 s, fall back to
the question fetch. lostResponse T0 covers both branches.

**9. §2 `new_ticket` conflict reuses `rid_conflict` — should.**
Objection: `rid_conflict` has a protocol meaning (same rid, other bytes). The doc already models `not_found` as
sealed HTTP-style data, "not a new bridge refusal"; logical-id conflict should follow the same rule. Also the meta
carries `host_api`, contradicting "never add host_api" to protocol ops' shape (nit). Change: 409 data
`{"host_api":0,"error":"creation_conflict"}`; keep `host_api` in new_ticket meta only if listed as an explicit exception.

**10. §4 Drop routes deviate from §10.6 — should.**
Objection: §10.6 already defines `PUT /drop/{id}/versions` with `If-Match` (no version in path) and the doc keeps
§10.5's `POST /drop/{id}/claim` verbatim, yet invents `PUT R/drop/{id}/versions/{version}`. Version-1 create
without `If-Match` contradicts §10.6's 428 rule. Change: use §10.6's route and status codes unchanged; invent only
list/get and an explicit version-1 rule (e.g. `If-Match: 0`), marked as a §10.6 amendment request.

**11. §1/§3 `leave` transport call — should.**
Objection: `leave(_ body:, session:)` has no workspace parameter although its route is `/workspaces/{ws}/leave`; the
route only does what `unregister` with `registration_id: null` would do, and the name suggests a membership exit to
P3. Change: drop `leave` from RelayTransport; allow `unregisterPush` with null id = all of this device's
registrations in that workspace.

**12. §2 WorkspaceAPI surface — should.**
Objection: `files` in the snapshot duplicates DropService (two sources of truth for the Files segment); there is no
`ticket(key:)` or question re-read for the sign sheet (see 1). Change: remove `files` from snapshot; Files uses
DropService only; WorkspaceAPI = snapshot, review, decide, pendingDecisions, newTicket, events.

**13. §2 5-second full-snapshot polling — should.**
Objection: every poll is a new bridge request: a seq, a rid record for 900 s (~180 per device per 15 min) and a
v1 §5.3 quota charge (`busy`, MAX_RECORDS, not checked here). Change: poll only while a workspace screen is
foreground, 15 s with backoff, immediate on verified push/open; T0 asserts a 30-minute session never gets `busy`.

**14. §5 vector table, phone row — should.**
Objection: the phone signs decisions and login and verifies lists and push, yet `decisions`, `question_hash`,
`relay_auth` (signed bytes), `member_lists` and `push.cases` are assigned only to fakes. Change: add them to the
phone row so phone and fake cannot agree on a wrong encoding (P2).

**15. §5 C1, per-realm device keys — should.**
Objection: "Device Demo keys still use Secure Enclave" does not say they are distinct from live keys. With
D-1 (keys survive leave) and `device_id = H(dk_sig_pub)`, a shared key gives one device_id a Demo cert from a fake
PK and a live cert. Change: separate `dk_sig`/`dk_kx` per realm, tagged by realm; Reset of Demo never touches live
keys; the capability token (`DemoCapability`) has no public initializer and is minted only by realm bootstrap.

**16. §7 slices are not right-sized — should.**
Objection: OrchProtocol at 0bc73c8 has no ORB2 envelope, §8.6/§8.8 pipelines, card/delegation, member-list, grant,
cert_request/challenge or Drop codecs (only `SignedKind` names), and OrchStore/OrchCustody are stubs (build step 3).
Slice 2 would carry all 47 host_cases, FakePrimary, the coordinator and card/CK; slice 4 mixes push, Drop and wipe.
Change: slice 0 = pure OrchProtocol completion with vector T0s (bridge.seal/device_cases, card.cases,
member_lists, wk_grants, cert_request.*, relay_auth, drop.*); split 2 into 2a FakeHost §8.6 + BridgeSession
(host_cases, device_cases) and 2b pairing; split Drop out of 4. State the dependency on M3 store/custody.

**17. §7 Release C1 tests and keychain T0s — should.**
Objection: `swift test -c release` cannot use `@testable`, which the vector tests need (`SoftwareSigner(testScalar:)`
is internal); keychain lookup denial cannot be proven in plain SwiftPM tests (T2 makes keychain hosted tests).
Change: a separate public-API-only C1 test target for Release; `testDemoCannotLookupLiveKeys`/`ResetScope` as hosted
app tests, not T0.

**18. Nits.** Use `ID16` (public, Sendable) instead of `String` ids in RelayTransport; treat `WireReply.headers`
case-insensitively; `epoch: UInt32?` admits 0; `after` should be `UInt64?` like the header seq; `events()` must
return a fresh stream per call (AsyncStream is single-consumer); say that TestClock is in-house (no swift-clocks,
A14) and `any Clock<Duration>` is used only via `sleep(for:)`; clarify that the 10-minute "pre-approval cap" ends at
host approval and does not cut cert_pending short.

verdict: converge with listed changes
