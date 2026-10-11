# Plugging the real relay and host into orch mobile

This is the checklist for replacing FakeRelay/FakeHost with a real relay (P3) and host (P2).
It is an integration proposal, not a declaration that protocol v2 already specifies these routes.
Baseline: `develop` checkout `5423757`, 10 October 2026; [host API v0](host-api-v0.md),
[decisions](decisions.md) P1–P5, and every section of [gaps](gaps.md).
Protocol section numbers refer to `orch-relay/docs/protocol-v2.md` in the sibling repository.

Branch evidence below was read with `git show`, without checking out or merging branches:
- `origin/feat/slice2a-bridge` at `2fc0732`: `OrchKit/Sources/OrchClient/WorkspaceSession.swift`,
  `OrchKit/Sources/OrchFakeHost/{HostBridgeCore,FakeHostBridge}.swift`, tests and `docs/gaps.md`.
- `origin/feat/slice2b-pairing` at `91e2ea0`: `OrchKit/Sources/OrchClient/PairingCoordinator.swift`,
  `OrchKit/Sources/OrchFakeHost/{FakeHostPairing,PairingScenarios}.swift`, tests and `docs/gaps.md`.
- `origin/feat/m8-share` at `3d2a198` (the local `feat/m8-share` is at a different commit, `b2e9d1f`): `OrchKit/Sources/OrchShareStaging/` and `ShareExtension/ShareViewController.swift`.
“Slice 2a/2b gap” links below target the respective section when that branch's gaps are merged;
those sections are absent from this checkout's `docs/gaps.md`. The bold item names identify them now.

The current `App/HomeScreen.swift` constructs `PreviewWorld`; it is a UI simulation.
Slice 2a supplies the bridge engine, but its defaultHostHandler returns not_found for http;
the host-view schemas below are requirements from host API §2, not implemented snapshot evidence.
`OrchClient` has the wire adapter, but WorkspaceSession and PairingCoordinator are branch evidence.
`FakeRelay.swift` answers 404 `not_found` for push registration (not in protocol-v2 §19 yet); its Drop routes work.
`OrchShareStaging` is absent locally; the current share extension is a disabled placeholder.
Completing these integrations and connecting the screens remains necessary before a sender swap works.

## A. The swap point: an HTTPS RequestSender

Use `RoutedRelayTransport<HTTPSRequestSender>` implementing `RequestSender.send(WireRequest)`.
The shared route builder stays in place; `InProcessRelayTransport` currently wraps the same builder
with FakeRelay. Transport carries bytes; protocol/coordinator/session code verifies authority.
Sources: `OrchKit/Sources/OrchClient/{Wire,RoutedRelayTransport,RealmContext,RelayClient,HostAPI}.swift`;
`OrchKit/Sources/OrchFakeHost/InProcessRelayTransport.swift`; host API §1; decisions A4–A6.
The routed initializer is package-scoped: a production factory inside OrchKit is still needed.

- [ ] Fix one reviewed HTTPS origin and RealmContext at construction; admit it on every send.
  Pin the origin, separately from PK/WSK cryptographic identity pins. No TLS certificate-pin scheme
  is specified here: that would be an open question, not an implied requirement of RealmContext.
- [ ] Require RelayURL syntax and byte-equal signed-card origin; show ASCII/punycode hosts.
  Reject userinfo, invalid ports and numeric/IP-like final labels per Slice 0 “Relay URL”.
- [ ] Reject every redirect, including same-origin redirects; Wire.swift explicitly requires this.
  Never forward bearer credentials, a pairing fragment or a signed login to a redirected target.
- [ ] Keep ATS enabled: `App/Info.plist` has no ATS exception. The HTTPS sender is not implemented;
  its TLS/ATS failure tests are a P3 gate, not existing evidence. No insecure fallback is proposed.
- [ ] Stream and cap response bytes before buffering/parsing, including error bodies and decoded
  content if HTTP content decoding is used. Do not rely on an honest Content-Length.
- [ ] Agree route-specific HTTP caps: HostAPI JSON parser currently allows 2 MiB; ORB2 requests
  allow 1 MiB and response envelopes 256 KiB; pairing envelopes allow 64 KiB; meta allows 64 KiB.
  Base64 and wrapper overhead count toward the HTTP cap separately from decoded-envelope caps.
  A large poll batch must not exceed the JSON cap; use the cursor. Exact batch cap is provisional.
- [ ] Resolve Drop JSON/base64 versus the 25 MiB compose limit and 2 MiB adapter cap before upload.
  Streaming/packaging changes need agreement; do not silently increase every response limit.
  Slice 2a also bounds accumulated bridge response data to 8 MiB; that is a local implementation cap.
- [ ] Preserve case-insensitive headers and reject conflicting singleton values (`WireReply`).
  Parse Retry-After as decimal delta-seconds, clamped to 1–3600; HTTP dates are ignored.
- [ ] Keep HTTP failures as WireReply values; throw for cancellation/I/O/realm violations.
  An unsigned HTTP error is never a verified host refusal or proof of revocation.
- [ ] Bind login signature to `transport.context.origin` and the identity's realm before first I/O.
  Sessions are per relay+realm, with membership authorization per workspace (gap 23, provisional).
  Challenges last 60 s and are consumed on every attempt; sessions last 15 minutes (§12.2).
- [ ] Keep bearers out of logs, NSE, share extension and URLs; validate visible ASCII, ≤512 bytes.
  Slice 2a renews 30 s before expiry and retries once after adapter `unauthenticated`.
  Preserve stored request bytes across renewal; never retry a mutation by constructing a new answer.
- [ ] Preserve Demo isolation: only `https://relay.demo.invalid`, in process, fresh synthetic authorities,
  realm-tagged custody and generation checks. A live sender must be unreachable from Demo (P3/A6).
- [ ] Use the server-observed peer address for limits. `WireRequest.clientAddress` is fake test input,
  not an authenticated HTTP field that the relay may trust from a client.

## B. Relay route contract

`R = /v2` (protocol-v2 §19). Relay requests and responses have no `Orch-Host-API` header and no `host_api` field:
JSON field sets are exact and strict (§2.3), errors are §14 `{"error": code, ...}`, `Retry-After` is integer delta-seconds.
(`host_api:0` inside bridge-tunnelled HOST views, `/v2/snapshot` and friends, is not a relay route and is unchanged.)
Rows marked "not in §19" (session logout aside, push, Drop) are still provisional pending orch-4e.
`D` = device bearer; `H` = workspace/host bearer; `–` = no bearer.
`J` = 2 MiB local JSON cap, not an upstream wire rule. `B` = 60 s mailbox retention.
`chunks` means `{chunks:[{id,idx,last,stream,envelope:b64u(ORB2)}]}`; validate against the header.
`after` is an optional strict unsigned decimal chunk index, absent before chunk 0; polls do not consume.
Sources for every row: host API §§1,3,4 and `RoutedRelayTransport.swift`, `HostAPI.swift`, `FakeRelay.swift`.

| Method | Path | Auth | Request → response | Refusals/errors | Limits; authority |
|---|---|---|---|---|---|
| POST | R/session/challenge | – | `{}` → 200 `{challenge:b64u32,expires_ms}` | 400 malformed; 413 too_large; 429 rate_limited | 16 KiB; 60 s challenge; §12.2, §19.1 |
| POST | R/session/login | – | `{challenge,kind:"device" or "workspace",id,sig:b64u64}` → 200 `{token,expires_ms}` | 400 malformed/cert_invalid/cert_expired; 401 bad_signature/unknown_challenge/expired; 403 revoked; 429 quota_exceeded (8 live tokens/device) | 16 KiB; consumed challenge, 15 min session; §12.2, §19.1 |
| POST | R/session/logout | D or H | `{}` → 200 `{}` | 400 malformed; 413 too_large; 401 unauthenticated (no bearer) | 16 KiB; idempotent, 200 for unknown/expired token; §19.1; FakeRelay only, no phone call yet |
| POST | R/workspaces/{ws}/pair/{offer}/{rid} | – request (direction 1); W(g) + `Orch-Holder` answer (direction 2) | raw epoch-0 ORB2 → 202 `{}` | 400 malformed/too_large (ORB2 cap)/wrong_suite; 401 unauthenticated/unknown_workspace; 403 not_eligible; 409 fenced; 429 rate_limited/quota_exceeded; 503 overloaded | 64 KiB envelope; B; §8.3/8.9, §19.3 (pair_*_post.json) |
| GET | R/workspaces/{ws}/pair/{offer}/{rid}[?after=N&wait=s] | – | empty → 200 chunks | 400 malformed; 429 rate_limited/quota_exceeded; 503 overloaded | J; B; 120 polls/min/address; wait 0..25 (FakeRelay answers at once); §19.3 (pair_poll.json) |
| POST | R/accounts | – | `{invite,pk_pub,device_cert,challenge,sig}` → 200 `{person_id}` | 400 malformed/wrong_suite/cert_invalid; 401 bad_signature/unknown_challenge/expired; 403 not_eligible; 409 account_exists; 413 | 64 KiB; exact retry 200 by digest; `RelayClient.createAccount`; P3-D3 |
| GET | R/persons/{p}/cert-requests[?wait=s] | D(p), addressee | empty → 200 `{requests:[signed cert_request]}` (open/challenged, unexpired, this device) | 400 malformed/cert_expired; 401; 403 not_eligible/revoked; 429 quota_exceeded; 503 overloaded | `RelayClient.certRequests`; §19.3 |
| POST | R/cert-requests/{id}/challenge | D(p), addressee | `{challenge: PK-signed}` → 200 `{}` | 400 malformed/wrong_suite/cert_expired; 401 bad_signature/unauthenticated; 403 not_eligible/not_for_this_device/other_person/revoked; 404; 409 replayed/already_signed/other_workspace; 410 expired; 413 | 16 KiB; identical `cj(o)` (re-signed or not) → 200; `RelayClient.submitCertChallenge`; P3-D11 |
| POST | R/cert-requests/{id}/rejection | D(p), addressee | `{rejection: PK-signed cert_rejection}` → 200 `{}` | as challenge | 16 KiB; identical `cj(o)` → 200; `RelayClient.submitCertRejection`; P3-D11 |
| POST | R/persons/{p}/cert-requests | W(g) + `Orch-Holder`, card owner = p | `{request: WSK-signed}` → 200 `{request_id}` | 400 malformed/wrong_suite; 401 bad_signature/unauthenticated; 403 not_eligible/not_for_this_device/other_person; 409 fenced/other_workspace/replayed/request_open; 410; 413; 429 quota_exceeded | host route (FakeHost); 1 open per workspace, 64 per person |
| GET | R/cert-requests/{id} | W, the requester | empty → 200 `{state,challenge,cert,rejection}` | 400; 401; 403 not_eligible; 404 | host route (FakeHost); kept until expires_ms + 60 s |
| POST | R/workspaces/{ws}/bridge/{rid} | D(m) request; W(g) response (`Orch-Holder`) | raw ORB2 → 202 `{}` | 400 malformed/too_large/wrong_suite/cert_expired; 401 unauthenticated; 403 not_eligible/not_for_this_device/revoked; 409 rid_conflict/stale_epoch(`epoch`)/retry_exhausted (device), chunk_conflict/stale_epoch/fenced (host); 410 expired (host, unknown rid); 429 rate_limited/quota_exceeded; 503 overloaded | 1 MiB request / 256 KiB chunk; P3-D8/D9/D22; §19.3; fixtures replayed byte-exact |
| GET | R/workspaces/{ws}/bridge/{rid}[?after=N][&wait=S] | D(m), own mailbox | empty → 200 chunks | 400 malformed/cert_expired; 401 unauthenticated; 403 not_eligible/revoked; 429 quota_exceeded; 503 overloaded | J; B; §19.3; fixtures replayed byte-exact |
| GET | R/workspaces/{ws}/grants[?epoch=N] | D, current member | empty → 200 `{grants:[signedWKGrant]}` | 400 malformed; 401 unauthenticated; 403 not_eligible/revoked; 404 not_found | J; epoch ≥1; §7.3, provisional v0 |
| GET | R/workspaces/{ws}/members | D, current member | empty → 200 `{member_list:signedMemberList}` | same fetch errors | J; local 1024 members; §7.2, provisional v0 |
| GET | R/workspaces/{ws}/card | D, current member | empty → 200 `{card:signedCard}` | same fetch errors | J; sealed part ≤64 KiB locally; §7.1, provisional v0 |
| GET | R/workspaces/{ws}/card-key?card_seq=N | D, current member | empty → 200 `{workspace_id,device_id,card_seq,sealed:b64u}` | same fetch errors | J; seq ≥1, session recipient only; §5.3 purpose card, provisional v0 |
| GET | R/devices/{device}/revocation | – | empty → 200 `{record:PK-signedRevocation}` | 400 malformed; 404 not_found; rate policy to agree | J; §6.2; public signed record, provisional v0 |
| POST | R/push/register | D, current member, valid cert | `{workspace_id,registration_id,env,topic,token:b64u}` → 200 `{registration_id,registered:true}` | 400 malformed; 401 unauthenticated; 403 revoked/not_eligible/not_for_this_device | J; env sandbox/production/demo; gaps 14–16, provisional v0 (not in §19: orch-4e) |
| POST | R/push/unregister | D, registration owner | `{workspace_id,registration_id:id or null}` → 200 `{registration_id,registered:false}` | 400 malformed; 401 unauthenticated; 403 revoked/not_for_this_device | J; null removes this device's registrations for ws; provisional v0 (not in §19: orch-4e) |
| PUT | /drop/{id}/versions | D with eligible write scope | If-Match decimal + `{descriptor,wraps,blob:b64uORD2}` → 200 `{version}` | 428 precondition_required; 409 version_conflict with `current`; 403 not_eligible; §14 validation errors | §10.6 path/CAS; JSON and initial create provisional v0; cap unresolved (not in §19: orch-4e) |
| POST | R/drop/list | D with eligible read scope | `{workspace_id,direction:"received" or "sending"}` → 200 `{objects:[{descriptor,wraps}]}` | 401 unauthenticated; 403 not_eligible; malformed input | J; pagination/large lists open; §10 objects, provisional v0 (not in §19: orch-4e) |
| GET | R/drop/{id}/versions/{version}/descriptor | D, authorized recipient | empty → 200 `{descriptor}` | 401 unauthenticated; 403 not_eligible; absence policy open | J; §10, provisional v0 (not in §19: orch-4e) |
| GET | R/drop/{id}/versions/{version}/wraps | D, authorized recipient | empty → 200 `{wraps:[]}` | same Drop read errors | J; local wrap ≤1 KiB; §10.3, provisional v0 (not in §19: orch-4e) |
| GET | R/drop/{id}/versions/{version}/blob | D, authorized recipient | empty → raw ORD2 + version header | same Drop read errors | agree streaming cap; local codec memory cap 256 MiB; §10.2, provisional v0 (not in §19: orch-4e) |
| POST | /drop/{id}/claim | H only | existing §10.5 signed claim → existing §10.5 result | §10.5/§14 validation, not_eligible/already_claimed | protocol route; no phone transport method; no invented v0 body |

Every relay failure is §14 `{"error": code}` (plus only that code's documented fields); `RelayRefusal.statuses(of:)` fixes the
status/code pairs (including §19.6's `unauthenticated`, `not_found`, `too_large` 413, `overloaded` 503, `quota_exceeded`,
`fenced`, `grant_conflict`, `wrap_conflict`, `chunk_conflict`, `retry_exhausted`, `account_exists`, ...); any other pair is a bad reply.
`Retry-After` (429/503) is parsed as integer delta-seconds only and never assumed to be 5 s.
Sealed host errors belong inside ORB2, not in those HTTP bodies. HTTP 202 means queued, never accepted.
An empty chunks array means no answer yet. Do not interpret silence as approval or a signed refusal.

Pair POST limits are 60/min/workspace and 60/min/address; the fake's Retry-After defaults to 5 s but is configurable (never assumed by the client).
Bridge quota defaults to 128 live mailboxes per device/workspace. Both are provisional v0 limits.
Bridge delivery follows §19.3/§19.6 (host API §1, "Bridge delivery"): one replay record per device rid for 900 s
from first receipt, coalescing of live undelivered copies, requeue at most once per 10 s (429 with the rest of the
interval) and 8 times (then terminal 409 `retry_exhausted`), and P3-D22/D27 for host chunks (410 for an unknown rid, no
TTL refresh for a live duplicate, re-store of exact stored bytes only, bounded: 900 s from first receipt, 8 per chunk).
A host must keep its exact response-envelope bytes before the first POST and re-post only those. The phone keeps polling the same rid after 202/429, never reissues under a new rid on its
own, treats `stale_epoch` as an unsigned hint (bounded signed list/grant refetch, 3/min then 20/40/60 s; same-rid re-seal) and surfaces
`retry_exhausted` for an explicit user retry. The FakeRelay's acknowledged cursor is `pendingRequests(after:)`;
P3's real host uses `host/hold` + `host/poll` (P3-D10), which the phone never calls.
Expire ciphertext by receipt time, never by last read; remove empty mailboxes and idle rate windows.
Challenge cap 1024 is global in the fake; real P3 needs per-address fairness and dummy-key signature
verification for unknown identities. These are explicit Slice 1 gaps, not guarantees of the fake.

Host publication uses protocol-v2 §19.1/§19.2: `PUT /v2/devices/{device}`, `POST /v2/revocations` (PK-authorized, no session),
`PUT /v2/workspaces/{ws}/card` (first card session-less, then W(g)), and **one atomic** `PUT /v2/workspaces/{ws}/membership`
`{member_list, grants, card_key_wraps?}` → `{list_seq, epoch}` (W(g), `Orch-Holder`), plus `PUT card-keys` for later wraps.
The FakeRelay serves these routes (and `publishCertificate/publishCard/publishRevocation` as in-process stand-ins); the hold route
and `pendingRequests`/pairing inbox access are still fake internals (host-only, orch-core).
Write-time authority: host session and holder (the strict lease on every W(g) route, pairing answers and cert requests included;
fenced without `Orch-Holder`), current card, each member's certificate valid now and owned by the card owner or a listed person,
non-revocation. Sequence (orch-29 Q10): a first list has `1 <= epoch <= 2^16` and any `list_seq >= 1`; then `list_seq` increases,
`prev <= epoch <= prev + 2^16`, a removal needs `epoch > prev`, and the same epoch needs the same `wk_commit` (409 `wk_commit_changed`).
Grants and wraps are judged against the list in the same body; nothing is staged.
Host obligations (Q10, pending orch-52): one WK per epoch, ever. A refused publication burns its epoch (key retained, never activated
or resealed; `list_seq` and epoch floors rise to the refused body's; the next rotation goes to floor + 1); `stale_card`/`wrap_conflict`
resend the same signed list with fixed wraps; a same-epoch addition refused with `revoked`/`cert_*` forces a rotation.

## C. Host obligations

### Bridge §8.6, persistence and host API

Implement the following order, not merely the same collection of checks.
Source: Slice 2a `HostBridgeCore.swift`, `FakeHostBridge.swift`, `WorkspaceSession.swift`; host API §§1–2.
1. Check full envelope size, magic/version/suite, direction/flags, workspace and mailbox/rid.
2. Find the request epoch key; silently drop future/unknown epochs and missing keys.
3. Authenticate/decrypt the tag before considering device refusals; bad tags are silent.
4. Check revocation, membership and device signature, with the unverified-refusal budget.
5. Consult rid record before freshness checks: different device/digest gives `rid_conflict`;
   identical bytes replay stored response bytes, recorded refusal, or `already_done(status)`.
   Enforce live-record quota before accepting a new request.
6. Parse meta/data framing; invalid framing produces recorded `malformed`.
7. Consume/check the device's 64-entry sequence window; refuse `stale_sequence(high)`.
8. Check timestamp window; refuse `stale_timestamp(host_ms)`.
9. Check current epoch; refuse `stale_epoch(epoch)`.
10. Check stream ownership; refuse unauthorized stream use.
11. Record the request, then enforce operation scope/native supported-op rules before running its handler;
    finish with a replayable result or unknown outcome. Scope refusal must remain recorded.

Persist seq window and rid store atomically with the decision to run; a restart must not re-execute
an accepted request. The fake is an in-memory model, not evidence of durable host storage.
Rid records expire at receipt +900 s; prune them before quota counts. Slice 2a defaults imported from
v1: 1024 records/device, 16384 total, busy allowance 64; unverified refusals 10/60 s host-wide.
Agree these quotas with P2 and test restart/crash boundaries against real storage.
Host refusals also include forbidden_scope, busy, scope_changed and stopped as applicable (§14);
never echo untrusted request text in a refusal. The phone renders fixed local explanations.

After the handler, re-check epoch, membership and revocation before sealing data.
Wait for in-progress rotation; keep durable `rotationRequired` until publication completes.
On changed authority return `already_done(unknown)` rather than sensitive old-epoch data.
Rotation ends streams with `LAST|REFUSAL stale_epoch`; the revocation operation's own non-sensitive
`{"revoked":true}` was the exception sealed with the request's epoch. Under protocol-v2 P3-D22 an old-epoch chunk must be
`LAST|REFUSAL`, so (orch-29 Q12) the host posts, only after the rotation commits, `already_done` with a whitelisted outcome
(`completed`|`failed`|`unknown`) as that refusal. It is advisory: "revoked" comes only from the signed list at the higher
epoch without the device; 202 never means completed. A host must also answer `rid_conflict` for
a same-rid copy with other bytes (the phone re-seals under the same rid after the relay's `stale_epoch` hint).
A host must also store the exact bytes of every answer it sends, refusals included: the relay keeps the digest of each
`(rid, idx)` and refuses re-sealed bytes for a stored index (409 `chunk_conflict`).

Support host API §2 allow-listed `http`: GET `/v2/snapshot`, `/v2/tickets/{key}`,
`/v2/questions/{question_id}`, headers `{}`, empty data. Reject arbitrary URLs, queries and traversal.
Reads require look; decisions decide; new_ticket operate. Response chunk 0 holds HTTP-style status
and content-type, later meta `{}`, LAST terminates; WSK signs and request K_bridge seals each chunk.
Snapshots are consistent, with persisted monotonic revision; members' labels come from the host registry.
Never substitute a bridge name for the verified sealed-card workspace name (D-6).
Implement exact question/hash/option/resolution and ticket schemas in host API §2, including nulls.

Verify detached §13 decisions before atomic compare-and-set; persist immutable decision_id/answer.
A changed hash requires `question_changed`; a competing decision returns `already_answered` who/when.
Provide authoritative question reads to reconcile lost responses by decision_id AND answer.
The phone starts a byte-identical resend only within ~240 s (900 s minus 660 s margin, orch-29 Q11), using the larger
of monotonic and persisted wall age; afterward mark uncertain and reconcile without silently re-signing.
This is stricter than host API §2's broad 900 s description; use branch behavior until reconciled.
For new_ticket, persist `(device_id,creation_id,canonical request,ticket)` atomically and indefinitely
in v0; identical retries reuse the ticket, changed fields give HTTP-style sealed 409 creation_conflict.
Keep logical identifiers across new envelopes; do not confuse logical idempotency with rid replay.
Budget foreground snapshot polling (15/30/60 s) with mutations; a 30-minute session must not self-exhaust.

### Pairing and the primary

Source: host API §§3,5–6; Slice 2b `PairingCoordinator.swift`, `FakeHostPairing.swift`, `PairingScenarios.swift`.
- Issue single-use offers with random S and sas_nonce; offer lifetime 10 minutes, used records 24 h.
  Link is `https://<relay>/app/pair#v2.<ws>.<offer>.<S>.<wsk_pin>.<pk_pin>`; `/pair` is an alias.
  Custom scheme needs explicit reviewed origin; never transmit or log the fragment.
- Use epoch-0 K_pair and phone dk_sig requests; WSK signs answers, each including wsk_pub.
  Unknown offer/bad tag is silent; explicit refusals follow the five/offer/minute budget.
  The five answer states are pending, cert_pending, approved, rejected and expired (§8.3).
- Echo both phone keys; pin SAS nonce/owner/challenge. Approval is an explicit code comparison,
  never a timer or transport success. Do not regress state or substitute a challenge after display.
- If certification is needed, send §8.4 cert_request signed by WSK and sealed to the primary's dk_kx.
  The inner carries device_id, both keys, cleaned label, scopes_max, offer_id and the phone's `attempt`; `o` repeats
  offer_id, attempt, device_id and dk_hash in clear (P3-D28), and the primary refuses a mismatch with the inner (malformed).
  Primary verifies the request/delegation, opens stored keys, issues one pinned challenge and signs
  those exact keys only after cert-code confirmation. The phone never holds PK/PVK (D-2).
- Queues are §19.3 routes (P3-D11): the host posts its request with W(g) and reads
  `GET /v2/cert-requests/{id}`; the primary polls, challenges and rejects with its own device session
  (D(p), addressee). Rejection is the PK-signed `cert_rejection` (label `orch/v2/sig/cert-rejection|`).
  The host verifies it under PK for its request (and the attempt binding) and relays it unchanged in the long
  `rejected` form `{"state":"rejected","wsk_pub","pk_pub","rejection"}`; its own rejection is the short form.
  The pair request meta is exactly `{op, dk_sig_pub, dk_kx_pub, label, cert, attempt}`; a resend keeps the attempt,
  a new attempt (same keys) is `pairing_closed`. `approved` carries the join anchor `list_seq`, `card_seq`, `baseline`
  from relay-accepted objects only. The phone runs §8.4 step 5 and §8.3's rejected checks in the G3b order
  (keys/device before attempt and offer); only a full pass shows "Denied by the owner".
  A real host must not stall on a relay `rejection` that does not verify: ignore it and keep checking the
  challenge and both certificate sources (the request's and the directory's), as FakeHost does.
- Publish valid own-key certificate → one membership publication (list, every member's current WK grant, the CK wrap) → approved.
  No grant/CK wrap for an uncertified device. Re-check pending version around every suspension;
  rejection during publication wins, and removing an already-published member requires rotation.
- Phone verifies pinned PK delegation/WSK/card/origin, CK target and commitment, own member scopes
  equal approved.scopes, list epoch ≥ approved.epoch, and grant epoch equal list epoch before commit.
  Missing wrap/list/grant races may remain joining; bad CK never falls back to a plaintext name.
- Agree pending deadline, resend-after-state-change behavior and 60 s first-answer ambiguity.
  Branch join retry: 60 s attempt, retry until 10 minutes after approval or earlier cert expiry;
  erase S at pinned approval. Ready commits the workspace; this branch does not publish push material.

### Rotation, revocation and local removal

Sources: host API §3; Slice 1/2a gaps; `FakeRelay.swift`, branch `FakeHostBridge.swift`.
Publish the new signed list and every remaining member's new grant in one membership publication (P3-D7):
persist `WK_{e+1}` and the exact body first, resend those bytes after a lost reply, never reseal; epochs never skip.
A grant ahead of its list (no longer served by a v2 relay) would still not be used before verified epoch confirmation.
Member removal rotates; clean removed mailboxes/grants/subscriptions. Failed rotation blocks data
sealing and is retried. Revalidate upload authorization atomically at the final write.
PK revocation ends all device sessions and removes grants, CK wraps, queued requests and push registrations.
A revoked device cannot log in; signature verification precedes revealing `revoked`.
Keep the public PK-signed revocation route available without a session. Only verified PK revocation
for this device authorizes identity-wide wipe; unsigned 403 or WSK refusal merely triggers fetch.
Local Leave wipes first, then at most two cleanup attempts within 10 s with an existing session.
No new leave route or retained cleanup secret is specified; offline failure says “Finish on your Mac”.
Keep identity after last Leave (D-1); Reset removes it. `member_remove` requires Operate and rotates;
Look/Decide must not acquire a self-removal exception. Revocation is separate from both actions (U9).

### Push sealing and the native envelope

Sources: protocol §9; host API §3; `OrchKit/Sources/OrchPush/{PushMaterial,PushProcessor,PushSimulation}.swift`,
`NotificationService/NotificationService.swift`, `OrchKit/Tests/OrchPushFixtures/PushFixtures.swift`.
Host payload is exactly `{kind,id,label,ts_ms}`, label ≤80 code points; WSK signs its canonical bytes
with domain `orch/v2/sig/push|` + suite/ws/u32(epoch). Seal `{p,sig}` with SALTED-AEAD K_push,
label `orch/v2/push-msg`, AAD `orch/v2/push-aad|` + suite/ws/u32(epoch).
Outer JSON is `{v:2,ws,epoch,c:b64uCiphertext}`, at most 3072 bytes.
Use strictly increasing timestamps per (ws,id), including closure: max(now, prior+1).

The current NSE expects top-level `o` to be a **string containing that outer JSON**, not base64 of JSON.
A fixture-compatible native payload is the following; provider contract remains **provisional** (gap 14):
```json
{"aps":{"alert":{"title":"orch","body":"New activity"},"mutable-content":1,"sound":"default"},
 "o":"{\"v\":2,\"ws\":\"<hex16>\",\"epoch\":1,\"c\":\"<b64u>\"}"}
```
The fixture's simulator-only `Simulator Target Bundle` is not an APNs payload requirement.
P3 must agree provider headers/topic, expiration/priority and total payload byte budget including
JSON-string escaping; a 3072-byte outer cap alone does not prove the native envelope fits.
Use registration env to choose gateway: TestFlight production, Xcode sandbox; Demo uses no APNs.
Omit `apns-collapse-id` (D-4/gap 10). NSE sets local thread identity and removes the delivered question
by scoped entity key on closure; the NSE cannot set provider headers. Do not collapse on naked id.

Publish derived K_push, pinned WSK, verified card name and generation before registration.
PushMaterial is one atomic keychain item, ≤16 KiB, ≤8 epochs, name ≤200 scalars; never store WK there.
Key retention/rotation races need agreement; missing epoch may produce generic alert, then foreground reconcile.
Native rejected/expired/join pushes show “New activity in orch”, without route/sound/thread.
No fetch/signing in NSE; never trust relay-authored alert fields or tap userInfo as authority (A12/U10).
Replay is per workspace/generation, with durable floor surviving wipe; id ≤128 UTF-8 bytes,
512 ids/workspace maximum without eviction; rollback of clock cannot resurrect a shown push.
Material/generation, replay writes and handoff obey removal locks; timeout can consume a replay slot
without showing verified text. A visible notification is not proof the NSE ran: require its marker.

### Drop and Share

Sources: host API §4; protocol §§7.5,10; `OrchKit/Sources/OrchProtocol/Drop.swift`;
M8 branch `OrchShareStaging/{Stager,Manifest,ShareArea,Inbox}.swift`; decisions U11/A10–A11.
Verify descriptor authority, expiry, recipients, content_hash, dek_commit and document chain identity.
Enforce CAS: initial create uses provisional If-Match 0/version 1/null parent; later versions bind head.
Persist reader highest version; same parent_hash alone must not allow a different object/space/kind.
For `{op:"drop_rewrap",object_id,version}` (§7.5), check reading scope, open the old epoch's wk wrap,
then upload a wrap of the same DEK under the current epoch using the workspace session.
Do not give newly joined devices historical WK grants. Host claim remains a WSK-authorized §10.5 action.
DropService packaging, streaming, list pagination and rewrap success projection remain integration questions.
Share stages protected plaintext only: no keychain access, signing or networking in the extension.
M8 copies files incrementally, commits manifest then atomic READY under generation coordination;
the foreground app imports, seals and sends. Removed destinations are quarantined, never redirected.
Five attachments/25 MiB total plaintext and default seven-day expiry are prototype limits, not wire rules.
URLs are literal text, never fetched. M8 still imports OrchStore coordination; reconcile with M7's
OrchCoordination extraction and extension-link audit before shipping the combined build.

## D. Protocol amendments to agree

### Must agree before real integration

Each entry links to its gap item; named subsection items are unnumbered in the source.
- [Gaps 4–8](gaps.md): native suite-2 pairing, origin-bearing links, aliases, associated-domain allowance,
  no passkey registration/assert and no Type in P4 (D-3/D-5); keep owner pin checks.
- [Gaps 9,25,27,29](gaps.md): allow-listed host view, exact schemas/scopes, new_ticket idempotency,
  decision reconciliation, labels from host, verified card/CK identity (D-6), Drop packaging/create/rewrap.
- [Gaps 10,13–19](gaps.md): native o/aps/provider envelope, registration/env, no collapse id,
  timestamp ordering, retained key epochs and generic fallback; join has no special visible content.
- [Gaps 20–24,26,28](gaps.md): cleanup authorization after wipe, identity retention, session scope,
  public revocation fetch, grant/list/card routes, phone never primary, same-person-only P4 boundary.
- [M2 “JSON nesting depth”, “§2.5 cleaning”, “§2.3 string comparison”, “Parser differential on object keys”,
  “§1.2 / §2.3 and -0”](gaps.md#m2-protocol-ambiguities): 16 container levels, Unicode-version agreement,
  byte comparisons, ASCII object keys and -0→0 canonicalization; add differential vectors.
- [M2 revocation id/refusal-order, §9 drop reasons/replay clock, §13 content_hash items](gaps.md#m2-protocol-ambiguities):
  agree exact refusal precedence, no replay after clock rollback, and signature over transmitted hash.
- [Slice 0 “Hosted marker”, counter ranges, Relay URL, signed-object refusal mapping, cert-request shape,
  “Challenge issuance”](gaps.md#slice-0-additions): resolve empty hosted_by discrepancy, u32 counters,
  one challenge/request and non-drop scope prefixes, with matching vectors.
- [Slice 0 “Device response check”, “Sealed WK”, “Input caps”, “Snapshots versus publication”,
  “Drop” and “Drop chain identity”](gaps.md#slice-0-additions): retire rid at LAST, repeated offset checks,
  local no_key/authentication failure handling, explicit caps, forward snapshot jumps and identity-bound chains.
- [Slice 1 additions](gaps.md#slice-1-additions-relay-model-for-orch-relay-p3-to-agree): revoked login/cleanup,
  per-address challenge fairness, pruned rate windows, dummy verification, receipt-time TTL,
  atomic upload checks, whole-envelope caps and delta-seconds Retry-After.
- [Slice 2a “Persist the seq window and the rid store atomically together”, “A re-send is never re-signed”,
  “After the handler”, “A grant ahead of its list”, “Pin-failure counter is consecutive”, rid pruning,
  “Rotation gates all data sealing”](gaps.md#slice-2a-additions-host-bridge-and-workspacesession-for-the-real-host-and-for-v1-to-agree):
  adopt the persistence, retry and rotation rules in C; reconcile the older host API wording.
- [Slice 2b additions](gaps.md#slice-2b-additions-pairing-verified-identity): define primary queues/rejection,
  pending deadline, resend current-state semantics and silence diagnosis; agree regression/pin alarms,
  safe primary label, stored owner certificate, join check order/retry bounds and recovery.
  “Not in this slice: push publication vs §6 ready” is a phone integration gate, not host proof.
- [M7 additions](gaps.md#m7-push-additions-phone-side): document per-workspace replay/floor/generation,
  128-byte/512-id limits, fail-closed corruption/expiry, lock-protected handoff, clock behavior,
  generic rejection/join, untrusted taps and invocation-marker evidence. These are native constraints;
  do not turn phone-local file layout/locking into relay wire fields.

### Nice to have for this integration; still tracked

- [Gaps 1–3,11–12,31–32](gaps.md): clean stale non-goal/Face ID/one-key/background-delivery/test prose
  and issue descriptions. Integration still follows D49, A6/A8 and hardware evidence, not stale prose.
- [Gaps 8–9,26,28,30](gaps.md): Type assertion replacement, non-question canonical sign summaries,
  primary-phone/multi-person support and background Share authorization are future features.
  They are not prerequisites while explicitly excluded; enabling any promotes its contract to must-agree.
- [M7 “Threat-model note” and “A3 amendment”](gaps.md#m7-push-additions-phone-side): update architecture
  prose for the surviving content-free floor and OrchCoordination linkage; keep current local safeguards.

## E. Contract and P3 end-to-end tests

Retarget wire scenarios through HTTPS with test-owned identities and host fixtures, not Demo credentials.
The following are **existing names**, not a claim that the suites already run remotely.
Paths are under `OrchKit/Tests/OrchFakeHostTests/` unless a row gives another path. Rows prefixed Slice 2a/2b exist only on those
unmerged branches (names confirmed by grep there); the other rows exist on this checkout. Branch prefixes match the provenance above.
Internal fake inspectors/fault hooks need real test-server equivalents; assert durable state as well as replies.

| Source | Existing tests/scenarios to carry across | Contract assertion |
|---|---|---|
| RelayAuthTests.swift | `testRelayAuthVectors`; `challengeIsSingleUseExpiresAtSixtySecondsAndSessionAtFifteenMinutes`; `loginSignsTheRelaysOwnOriginAndKnownIdentitiesOnly` | §12.2 bytes, origin binding, challenge consumption, expiry |
| RelayAuthTests.swift | `aRevokedDeviceGetsNoSessionAndReadsItsRecordWithoutOne`; `revocationDropsQueuedRequestsOfTheRevokedDevice` | no revoked session; public verifiable record; cleanup |
| RelayTests.swift | `testRelayHeaderSessionBinding`; `responsesComeOnlyFromTheHostAndPollIsNonConsumingWithCursor` | header/mailbox auth, non-consuming cursor poll |
| `OrchKit/Tests/OrchClientTests/WireTests.swift` | `testPollCursorUInt64`; `testAdapterVersionRejected` | cursor and adapter-version behavior (client side, not FakeHostTests) |
| RelayTests.swift | `testMemberListRequiresGrantsBeforePublish`; `memberListChecksCertificatesScopesAndRevocation`; `cardGrantAndCardKeyAreFetchedByTheMemberOnly`; `noGrantOrCardKeyForAnUncertifiedDevice` | publication order and recipient isolation |
| RetentionLimitsTests.swift | `expiredBodiesAndEmptyBoxesAreDroppedNotJustHidden`; `idlePollsDoNotKeepABoxAlive`; `aRequestOfExactlyMaxRequestIsQueuedAndOneByteMoreIsRefused`; `aResponseChunkOfExactlyMaxChunkPassesTheRelayAndTheDevicesCheckAndOneByteMoreFailsBoth` | physical TTL pruning and exact byte boundaries |
| LimitsFaultsTests.swift | `pairingRouteChecksHeaderAndNeedsNoBearer`; `pairingPostLimitsPerWorkspaceAndPerAddress`; `anHonestTenMinutePairingRunNeverHitsALimit`; `mailboxQuotaPerDeviceCountsLiveMailboxesOnly` | unauthenticated pairing with bounded fair limits |
| LimitsFaultsTests.swift | `faultDropAfterCommitKeepsTheRequestAndRetryIsIdempotent`; `pollFaultsDuplicateReorderCorruptAndDrop` | lost replies and hostile delivery |
| Slice 2a SessionTests.swift | `testLostResponseReplaysStoredEnvelope`; `testExpiredOrUnknownRidReconcilesByQuestion`; `testStaleEpochFetchesGrantsAndResendsAsNewRequest`; `testStaleTimestampAdoptsOffsetOnceAndRetries` | stored replay, uncertain result, epoch and offset recovery; question reconciliation itself still needs a host-view e2e |
| Slice 2a Hardening2a.swift | `S1_resendAfterHostRecordExpiredIsNotReRun`; `resendGateUsesMonotonicTimeWhenTheWallClockWasSetBack`; `hostSaidUnknownIsDurableUncertain` | no silent re-sign after unsafe resend window |
| Slice 2a Hardening2a.swift | `S3_revocationOpRotatesBeforeAnythingNewIsSealed`; `handlerFinishingDuringPublicationGetsNoData`; `failedPublicationKeepsRotationRequiredAndRetries`; `S4_nextEpochArrivesWithItsList` | durable rotation gate, no old-epoch data leak |
| Slice 2b PairingFlowTests.swift | `testPairingScenarioMatrix`; `testNoGrantOrCardWrapBeforeValidCertificate`; `testR1AlarmHidesBothCodes`; `testEchoWrongKeyAlarmBeforeSAS`; `testPairingPinsAndMonotonicChains` | real queues/approval without weakening pins or human gates |
| Slice 2b JoinVerificationTests.swift | `testCardWrongCKRejected`; `testCardOriginMatchesLink`; `testJoinRequiresOwnMemberScopesAndEpoch`; `testJoinCommitsOneWorkspaceAndEveryPieceOrNone` | verified identity and atomic join |

Matrix names from branch `PairingScenarios.swift`: firstTime, existingCert, hostIsPrimary,
primaryOffline, linkUsed, r1Attack, echoWrongKey, otherPerson, rejectOnHost, rejectOnPrimary, revokeAfter.
Run vectors independently on P2/P3: branch `testBridgeHostCases`, `testResultingStateOfEveryHostCase`,
`testPairHostCases`, `testPairAnswerVectors`, `testPrimaryCertRequestVectors`, `testPrimaryOpenCases`.
Keep realm/reset, parser, custody, UI and NSE unit tests local too; they do not become server tests merely
by changing a transport. The missing push route (Drop is faked) cannot substantiate a remote contract yet (P2/T1).

Add these **provisional P3 e2e scenarios**, separate from the Demo-only iPhone session:
1. HTTPS transport: bad trust/ATS failure, all redirects, oversized/chunked/error responses,
   conflicting headers, cancellation and bearer redaction; verify no cross-origin request occurs.
2. Real host + primary + phone: fresh and existing-cert joins, reject/expiry/R1 cases, restart at
   each publication boundary, delayed CK/list/grant, no partial join or notification-ready claim.
3. Host crash at seq/rid/handler commit boundaries: retain both replay defences; test all combinations
   of lost seq/rid state as fault cases; reconcile an unknown result without a duplicate decision/ticket.
4. Two devices answer concurrently; change question during review; disconnect after acceptance;
   reopen phone and reconcile authoritative answer without silently signing again (U7/U8).
5. Revoke/remove during a slow handler and failed rotation publication; confirm all sessions,
   mailboxes, grants, wraps and push subscriptions disappear and no sensitive old-epoch reply escapes.
6. Register/replace/unregister tokens idempotently across two workspaces and both APNs environments;
   offline Leave wipes immediately and later cleanup cannot remove another workspace's registration.
7. Production APNs on TestFlight with external credentials: marker plus verified/replay output;
   closure replacement without collapse-id, same id in two workspaces, locked/new-epoch/generic cases,
   malicious outer fields, late handoff after wipe and rejoin floor. This is outside Demo evidence.
8. Drop initial/CAS conflict, lost PUT response, cross-object chain, expired recipient, old-epoch rewrap
   for newly joined device without old WK; Photos/Files/Safari staging/import and large-file transport.
9. Thirty-minute foreground polling with mutations plus ten-minute cert_pending traffic: no self-busy,
   bounded queues/windows, Retry-After respected, malicious peer cannot starve another address.

Gate release on recorded relay/host/mobile revisions, vector provenance, runtime/device, outcomes and
remaining open contracts. Never mark an integration passed from a simulated UI or a fake-only round trip.
