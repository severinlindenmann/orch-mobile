import CryptoKit
import Foundation
import OrchClient
import OrchProtocol

// The relay's directory and membership tables (protocol-v2 sections 19.1, 19.2, 19.5) and the HTTP routes over them. Every check
// follows orch-relay's reference order (src/orch_relay/directory.py, members.py) so the shared HTTP fixtures and the p3 state
// vectors replay byte for byte. The tables hold public keys, signed objects and ciphertext only.

extension FakeRelay {
    /// A directory device row: the stored certificate and the columns the relay reads without re-parsing it.
    package struct DeviceRow: Sendable {
        package var cert: JSONValue
        package var personID: ID16
        package var expiresMs: Int64?
        package var scopesMax: [String]
        /// The certificate as verified when it was stored; nil for a row a test seeded with an unverifiable certificate.
        package var info: DeviceCertificate?
        package init(cert: JSONValue, personID: ID16, expiresMs: Int64?, scopesMax: [String], info: DeviceCertificate?) {
            self.cert = cert; self.personID = personID; self.expiresMs = expiresMs; self.scopesMax = scopesMax; self.info = info
        }
        package init(verified c: DeviceCertificate, cert: JSONValue) {
            self.init(cert: cert, personID: c.personID, expiresMs: c.expiresMs, scopesMax: c.scopesMax, info: c)
        }
        var isScopedAgent: Bool { scopesMax.first?.hasPrefix("drop:") ?? false }
    }

    package struct RevocationRow: Sendable {
        package var record: JSONValue
        package var personID: ID16
        package var reason: String
        package var cursor: Int64
        package init(record: JSONValue, personID: ID16, reason: String, cursor: Int64) {
            self.record = record; self.personID = personID; self.reason = reason; self.cursor = cursor
        }
    }

    /// The stored card (signed JSON as accepted) and the columns authorization reads.
    package struct CardRow: Sendable {
        package var json: JSONValue
        package var wsk: SigningPublicKey
        package var ownerPersonID: ID16
        package var cardSeq: UInt32
        /// The card as verified at acceptance; nil for a row a test seeded.
        package var verified: VerifiedCard?
        package init(json: JSONValue, wsk: SigningPublicKey, ownerPersonID: ID16, cardSeq: UInt32, verified: VerifiedCard?) {
            self.json = json; self.wsk = wsk; self.ownerPersonID = ownerPersonID; self.cardSeq = cardSeq; self.verified = verified
        }
    }

    package struct MemberRow: Sendable, Equatable {
        package var personID: ID16
        package var scopes: JSONValue
        package init(personID: ID16, scopes: JSONValue) { self.personID = personID; self.scopes = scopes }
        var scopeStrings: [String]? { scopes.array.flatMap { a in let s = a.compactMap(\.string); return s.count == a.count ? s : nil } }
    }

    /// P3-D10: the current holder generation and its lease.
    package struct Holder: Sendable, Equatable {
        package var gen: UInt64
        package var leaseUntilMs: Int64
        package init(gen: UInt64, leaseUntilMs: Int64) { self.gen = gen; self.leaseUntilMs = leaseUntilMs }
    }

    /// An accepted membership publication, by the SHA-256 of its exact HTTP body (section 19.7: seven days, not refreshed).
    package struct Receipt: Sendable, Equatable {
        package var listSeq: Int64
        package var epoch: UInt32
        package var acceptedMs: Int64
        package init(listSeq: Int64, epoch: UInt32, acceptedMs: Int64) { self.listSeq = listSeq; self.epoch = epoch; self.acceptedMs = acceptedMs }
    }

    /// Section 19.5: one obligation per revoked member device, cleared only by a higher-epoch list that excludes it.
    package struct RotationDue: Sendable, Equatable {
        package var cursor: Int64
        package var epoch: UInt32
        package init(cursor: Int64, epoch: UInt32) { self.cursor = cursor; self.epoch = epoch }
    }

    package typealias GrantKey = MemberList.Directory.GrantKey

    package struct Workspace: Sendable {
        package var card: CardRow?
        /// The current signed member list and its header; `members` is the relay's member table for it.
        package var listJSON: JSONValue?
        package var listSeq: Int64 = 0
        package var epoch: UInt32 = 0
        package var members: [ID16: MemberRow] = [:]
        /// Section 19.1: authority ever granted by an accepted list (never removed); device -> its first epoch.
        package var everPersons: Set<ID16> = []
        package var everDevices: [ID16: UInt32] = [:]
        package var grants: [GrantKey: JSONValue] = [:]
        /// Card-key wraps by device and card sequence, as the sealed b64u text the host sent.
        package var cardKeys: [ID16: [UInt32: String]] = [:]
        package var receipts: [Data: Receipt] = [:]
        package var holder: Holder?
        package var rotationDue: [ID16: RotationDue] = [:]
        package init() {}
        package var hasList: Bool { listJSON != nil }
        package var currentEpoch: UInt32? { hasList ? epoch : nil }
    }

    package struct RateWindow: Sendable, Equatable {
        package var endMs: Int64
        package var count: Int
        package init(endMs: Int64, count: Int) { self.endMs = endMs; self.count = count }
    }

    /// A refusal on the section 19 routes; the status is section 19.6's for the code unless the route overrides it.
    struct Fail: Error {
        let code: RelayRefusal.Code
        var status: Int?
        var retryAfter: Int?
        init(_ code: RelayRefusal.Code, status: Int? = nil, retryAfter: Int? = nil) { self.code = code; self.status = status; self.retryAfter = retryAfter }
        init(_ r: Refusal) { self.init(RelayRefusal.Code(rawValue: r.rawValue) ?? .malformed) }
    }

    static func status(of c: RelayRefusal.Code) -> Int {
        switch c {
        case .staleList, .staleEpoch, .badEpoch, .rotationRequired, .missingGrant, .wkCommitChanged, .grantConflict, .wrapConflict, .accountExists, .certConflict,
             .fenced, .holderConflict, .otherWorkspace, .wskChanged, .delegationChanged, .staleCard, .wxkChangedWithoutVersion, .badWxkVersion: return 409
        case .scopeExceeded, .notForThisDevice, .revoked, .notEligible, .otherPerson: return 403
        case .unknownChallenge, .expired, .badSignature, .unauthenticated: return 401
        case .notFound: return 404
        case .rateLimited, .quotaExceeded: return 429
        case .tooLarge: return 413
        default: return 400
        }
    }

    static let minuteMs: Int64 = 60_000, hourMs: Int64 = 3_600_000, dayMs: Int64 = 86_400_000
    static let receiptRetentionMs: Int64 = 7 * dayMs
    static let holderLeaseMs: Int64 = 40_000
    static let grantFields: Set<String> = ["v", "suite", "kind", "workspace_id", "device_id", "epoch", "sealed"]
    /// A suite-2 sealed 32-byte key (section 5.3): ephemeral P-256 point, ciphertext, tag.
    static let sealedKeyBytes = 65 + 32 + 16

    /// Whole-body caps (G0a review 2): checked before parsing, authentication or signatures.
    static func bodyCap(_ route: String) -> Int {
        switch route {
        case "membership": return 2 << 20
        case "card", "card_keys", "accounts": return 64 << 10
        default: return 16 << 10
        }
    }

    // MARK: routing

    /// The section 19.1/19.2 routes, or nil for any other path.
    static func directoryRoute(_ method: String, _ s: [String]) -> (route: String, ident: String?)? {
        if s.count == 3, s[0] == "workspaces" {
            switch (method, s[2]) {
            case ("PUT", "membership"): return ("membership", s[1])
            case ("GET", "members"): return ("members", s[1])
            case ("GET", "grants"): return ("grants", s[1])
            case ("PUT", "card-keys"): return ("card_keys", s[1])
            case ("GET", "card-key"): return ("card_key", s[1])
            case ("PUT", "card"), ("GET", "card"): return ("card", s[1])
            default: return nil
            }
        }
        if s.count == 2, s[0] == "devices", method == "PUT" || method == "GET" { return ("device", s[1]) }
        if s.count == 3, s[0] == "devices", s[2] == "revocation", method == "GET" { return ("revocation", s[1]) }
        if s == ["revocations"], method == "POST" { return ("revocations", nil) }
        if s.count == 3, s[0] == "persons", s[2] == "revocations", method == "GET" { return ("feed", s[1]) }
        return nil
    }

    func directory(_ r: WireRequest, route: String, ident: String?, _ query: String?) async throws -> WireReply {
        // A membership fault delay precedes every authoritative check: after it there is no suspension until the commit.
        if route == "membership" { _ = try await fault(.beforeMembershipPublication, r.method + " " + routePath(r.target)) }
        try checkLive()
        do {
            return json(200, try handle(route, ident, r, query))
        } catch let f as Fail {
            if f.code == .rateLimited || f.code == .quotaExceeded { rateLimited += 1 }
            let retry: [String: String] = (f.status ?? Self.status(of: f.code)) == 429 ? ["retry-after": String(max(1, f.retryAfter ?? 1))] : [:]
            return refuse(f.status ?? Self.status(of: f.code), f.code, headers: retry)
        } catch let r as Refusal {
            let f = Fail(r)
            return refuse(Self.status(of: f.code), f.code)
        } catch is RealmViolation {
            return refuse(403, .otherPerson)
        }
    }

    private func handle(_ route: String, _ ident: String?, _ r: WireRequest, _ query: String?) throws -> [String: JSONValue] {
        let cap = Self.bodyCap(route)
        guard r.body.count <= cap else { throw Fail(.tooLarge) }
        let now = wall.nowMs
        let digest = Data(SHA256.hash(data: r.body))
        let recovery = route == "revocations" || (route == "device" && r.method == "PUT")
        if recovery {
            // An exact retry of an accepted recovery is free; anything else is charged to the address first (P3-D5).
            let revocation = route == "revocations"
            let receipt = recoveryReceipts[(revocation ? "revocation:" : "certificate:") + Hex.encode(digest)]
            if receipt == nil || (!revocation && receipt?.hex != ident) {
                try rate(revocation ? "revocation-address" : "certificate-address", r.clientAddress,
                         durationMs: revocation ? Self.minuteMs : Self.hourMs, cap: revocation ? 10 : 30, now: now)
            }
        }
        var body: JSONValue = .null
        if r.method == "GET" {
            guard r.body.isEmpty else { throw Fail(.malformed) }
        } else {
            let type = r.header("content-type").map { String($0.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]).trimmingCharacters(in: .whitespaces) }
            guard type == "application/json", let v = try? StrictJSON.parse(r.body, maxBytes: cap) else { throw Fail(.malformed) }
            body = v
        }
        let allowed: Set<String> = route == "grants" ? ["epoch"] : route == "card_key" ? ["card_seq"] : route == "feed" ? ["after", "limit", "next"] : route == "revocation" ? ["after", "limit"] : []
        guard let q = queryItems(query, allowed: allowed) else { throw Fail(.malformed) }
        var id: ID16?
        if let ident {
            guard let x = ID16(hex: ident) else { throw Fail(.malformed) }
            id = x
        }
        switch route {
        case "membership", "members", "grants", "card_keys", "card_key":
            return try members(route, id!, r, body: body, q: q, now: now)
        case "revocations":
            return try recover(body: body, raw: r.body, now: now, device: nil)
        case "device" where r.method == "PUT":
            return try recover(body: body, raw: r.body, now: now, device: id!)
        case "revocation":
            try rate("revocation-read", r.clientAddress, durationMs: Self.minuteMs, cap: 60, now: now)
            // The real relay's shape (directory.py `revocation_pairs`): `{pairs, next}` with `?after=&limit=` (limit 1...32). This fake holds
            // one pair per device, so a valid `after` (any non-empty base64url) is a page past it: empty, `next` null. First page and no pair: 404.
            if let l = q["limit"] { guard let n = HostAPI.parseDecimal(l), (1...32).contains(n) else { throw Fail(.malformed) } }
            if let a = q["after"] {
                guard !a.isEmpty, B64U.decode(a) != nil else { throw Fail(.malformed) }
                return ["pairs": .array([]), "next": .null]
            }
            guard let row = revocationRows[id!], row.record != .null else { throw Fail(.notFound) }
            return ["pairs": .array([.object(["person_id": .string(row.personID.hex), "reason": .string(row.reason), "revocation": row.record,
                                              "provenance": "registry"])]), "next": .null]
        case "card" where r.method == "PUT":
            return try cardPut(id!, body: body, r: r, now: now, address: r.clientAddress)
        default:
            let s = try authorized(r, now: now)
            switch route {
            case "device":
                guard let row = devices[id!] else { throw Fail(.notFound) }
                try personAccess(s, row.personID)
                if s.kind == .workspace, workspaces[s.id]?.everDevices[id!] == nil { throw Fail(.notEligible) }
                return ["cert": row.cert]
            case "card":
                guard let card = workspaces[id!]?.card else { throw Fail(.notFound) }
                try workspaceAccess(s, id!, write: false)
                return ["card": card.json]
            default:
                return try feed(s, person: id!, q: q)
            }
        }
    }

    // MARK: authorization (section 19 Auth column, section 19.6)

    /// D or W: every request re-checks the session, and a device session its device row (revocation, then expiry).
    func authorized(_ r: WireRequest, now: Int64) throws -> Session {
        guard let h = r.header("authorization"), h.hasPrefix("Bearer "), let s = sessions[String(h.dropFirst(7))], now < s.expiresMs else {
            throw Fail(.unauthenticated)
        }
        if s.kind == .device {
            guard let d = devices[s.id] else { throw Fail(.unauthenticated) }
            if revocationRows[s.id] != nil { throw Fail(.revoked) }
            if let e = d.expiresMs, now >= e { throw Fail(.certExpired) }
        } else if workspaces[s.id]?.card == nil {
            throw Fail(.unauthenticated)
        }
        return s
    }

    /// W for its own workspace; D(m) for reads by a current, unscoped member device. Writes are W only.
    func workspaceAccess(_ s: Session, _ ws: ID16, write: Bool) throws {
        let ok: Bool
        if s.kind == .workspace { ok = s.id == ws }
        else { ok = !write && !(devices[s.id]?.isScopedAgent ?? true) && workspaces[ws]?.members[s.id] != nil }
        guard ok else { throw Fail(.notEligible) }
    }

    /// D(p), or W whose `ever_persons` holds the person through an admitted device of that person (G0a review 1).
    func personAccess(_ s: Session, _ person: ID16) throws {
        let ok: Bool
        if s.kind == .device {
            ok = devices[s.id].map { $0.personID == person && !$0.isScopedAgent } ?? false
        } else if let w = workspaces[s.id] {
            ok = w.everPersons.contains(person) && w.everDevices.keys.contains { devices[$0]?.personID == person }
        } else { ok = false }
        guard ok else { throw Fail(.notEligible) }
    }

    /// W(g): `Orch-Holder` must name the current generation of an unexpired lease (P3-D10).
    func fence(_ r: WireRequest, _ ws: ID16, now: Int64) throws {
        guard let text = r.header("orch-holder") else { throw Fail(.fenced) }
        guard let gen = HostAPI.parseDecimal(text), gen <= UInt64(maxSafeInt) else { throw Fail(.malformed) }
        guard let h = workspaces[ws]?.holder, h.gen == gen, h.leaseUntilMs > now else { throw Fail(.fenced) }
    }

    /// Fixed windows kept for their full duration (P3-D17); `charge: false` only tests the cap.
    func rate(_ purpose: String, _ identity: String, durationMs: Int64, cap: Int, now: Int64, charge: Bool = true) throws {
        let key = purpose + "|" + identity + "|" + String(durationMs)
        let fresh = RateWindow(endMs: (now / durationMs + 1) * durationMs, count: 0)
        var w = rateWindows[key] ?? fresh
        if now >= w.endMs { w = fresh }
        if w.count >= cap { throw Fail(.rateLimited, retryAfter: Int(max(1, (w.endMs - now + 999) / 1000))) }
        if charge { w.count += 1; rateWindows[key] = w }
    }

    /// Signature objects of another deployment suite are `wrong_suite` before anything else is judged.
    static func checkSuite(_ signed: JSONValue?) throws {
        if let s = signed?.object?["o"]?.object?["suite"]?.int, s != Int64(Suite2.id) { throw Fail(.wrongSuite) }
    }

    /// Suite gate, then the signature under `key`: any other failure of the signed object is `bad_signature`.
    static func verified(_ signed: JSONValue, key: SigningPublicKey, kind: SignedKind) throws -> [String: JSONValue] {
        try checkSuite(signed)
        do { return try SignedObject.parse(signed).verify(kind: kind, key: key) } catch { throw Fail(.badSignature) }
    }

    static func exact(_ o: [String: JSONValue], _ keys: Set<String>) -> Bool {
        o.keys.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { $0 < 0x80 } } && Set(o.keys) == keys
    }

    static func canonical(_ v: JSONValue?) -> Data? { v.flatMap { try? canonicalJSON($0) } }

    /// A sealed 32-byte key (section 5.3 framing): exactly 113 bytes whose first 65 are a valid P-256 point. The plaintext is opaque.
    static func sealedShape(_ v: JSONValue?) throws -> String {
        guard let s = v?.string, let raw = B64U.decode(s, length: sealedKeyBytes), (try? AgreementPublicKey(x963: raw.prefix(65))) != nil else {
            throw Fail(.malformed)
        }
        return s
    }

    // MARK: members, grants and card keys (section 19.2)

    private func members(_ route: String, _ ws: ID16, _ r: WireRequest, body: JSONValue, q: [String: String], now: Int64) throws -> [String: JSONValue] {
        let s = try authorized(r, now: now)
        let write = route == "membership" || route == "card_keys"
        try workspaceAccess(s, ws, write: write)
        if write { try fence(r, ws, now: now) }
        if route == "grants" || route == "card_key", s.kind != .device { throw Fail(.notEligible) }
        guard let w = workspaces[ws], let card = w.card else { throw Fail(.notFound) }
        switch route {
        case "membership":
            return try publish(ws, body: body, raw: r.body, card: card, now: now)
        case "members":
            guard let list = w.listJSON else { throw Fail(.notFound) }
            return ["member_list": list]
        case "card_keys":
            guard let list = w.listJSON?.object?["o"]?.object else { throw Fail(.notFound) }
            var listed: [ID16: MemberList.Member] = [:]
            for m in list["members"]?.array ?? [] {
                guard let mo = m.object, let d = mo["device_id"]?.string.flatMap({ ID16(hex: $0) }),
                      let p = mo["person_id"]?.string.flatMap({ ID16(hex: $0) }), let sc = mo["scopes"] else { continue }
                listed[d] = MemberList.Member(deviceID: d, personID: p, scopes: sc)
            }
            let persons = Set((list["persons"]?.array ?? []).compactMap { $0.string.flatMap { ID16(hex: $0) } })
            let wraps = try checkWraps(ws, body, card: card, members: listed, persons: persons, now: now)
            for x in wraps where workspaces[ws]?.cardKeys[x.device]?[x.cardSeq] == nil {
                workspaces[ws]?.cardKeys[x.device, default: [:]][x.cardSeq] = x.sealed
            }
            return ["stored": .int(Int64(wraps.count))]
        case "card_key":
            guard let text = q["card_seq"], let seq = HostAPI.parseDecimal(text), seq <= UInt64(maxSafeInt) else { throw Fail(.malformed) }
            guard seq != 0 else { throw Fail(.malformed) }
            guard seq <= UInt64(UInt32.max), let sealed = w.cardKeys[s.id]?[UInt32(seq)] else { throw Fail(.notFound) }
            return ["workspace_id": .string(ws.hex), "device_id": .string(s.id.hex), "card_seq": .int(Int64(seq)), "sealed": .string(sealed)]
        default:   // grants: the device's own, ascending, from the epoch it was first admitted
            var epoch: UInt64?
            if let text = q["epoch"] {
                guard let v = HostAPI.parseDecimal(text), v <= UInt64(maxSafeInt) else { throw Fail(.malformed) }
                guard v != 0 else { throw Fail(.malformed) }
                epoch = v
            }
            guard let first = w.everDevices[s.id] else { throw Fail(.notFound) }
            let mine = w.grants.filter { $0.key.device == s.id && $0.key.epoch >= first && (epoch == nil || UInt64($0.key.epoch) == epoch) }
                .sorted { $0.key.epoch < $1.key.epoch }.map(\.value)
            guard !mine.isEmpty else { throw Fail(.notFound) }
            return ["grants": .array(mine)]
        }
    }

    /// The write-time certificate check of a proposed member (members.py `certificate`): not revoked; a stored certificate whose
    /// person is the entry's, the row's, and the card owner or a listed person; an account for that person; the certificate valid
    /// for exactly this device under that account key now (an expired one is 403 here: it is a member's, not the session's); and
    /// scopes a prefix of its `scopes_max`, never a scoped agent.
    private func certificateCheck(_ m: MemberList.Member, owner: ID16, persons: Set<ID16>, now: Int64) throws {
        if revocationRows[m.deviceID] != nil { throw Fail(.revoked) }
        guard let row = devices[m.deviceID], let co = row.cert.object?["o"]?.object else { throw Fail(.certInvalid) }
        guard let person = co["person_id"]?.string.flatMap({ ID16(hex: $0) }), person == m.personID, person == row.personID,
              person == owner || persons.contains(person) else { throw Fail(.otherPerson) }
        guard let key = owners[person] else { throw Fail(.otherPerson) }
        let cert: DeviceCertificate
        do { cert = try DeviceCertificate.verify(row.cert, personKey: key, nowMs: now) }
        catch Refusal.certExpired { throw Fail(.certExpired, status: 403) }
        catch let r as Refusal { throw Fail(r) }
        guard cert.deviceID == m.deviceID else { throw Fail(.certInvalid) }
        guard !cert.isScopedAgent, let scopes = m.scopeStrings, Scopes.isValid(scopes), scopes.count <= cert.scopesMax.count,
              Array(cert.scopesMax.prefix(scopes.count)) == scopes else { throw Fail(.scopeExceeded) }
    }

    private struct WrapInsert { let device: ID16; let cardSeq: UInt32; let sealed: String }

    /// `card_key_wraps` / `PUT card-keys` (G0a review 10): the current card sequence, unique current members whose certificates pass
    /// the write-time check, the sealed framing, and `wrap_conflict` for other bytes under an existing (device, card_seq). Nothing is
    /// written here: the caller commits all of them or none.
    private func checkWraps(_ ws: ID16, _ body: JSONValue, card: CardRow, members: [ID16: MemberList.Member], persons: Set<ID16>,
                            now: Int64) throws -> [WrapInsert] {
        guard let wo = body.object, Self.exact(wo, ["card_seq", "wraps"]), let seq = wo["card_seq"]?.int, seq >= 1, seq <= maxSafeInt else {
            throw Fail(.malformed)
        }
        guard seq == Int64(card.cardSeq) else { throw Fail(.staleCard) }
        guard let items = wo["wraps"]?.array else { throw Fail(.malformed) }
        var seen = Set<ID16>(), out: [WrapInsert] = []
        for x in items {
            guard let xo = x.object, Self.exact(xo, ["device_id", "sealed"]), let did = xo["device_id"]?.string.flatMap({ ID16(hex: $0) }),
                  seen.insert(did).inserted else { throw Fail(.malformed) }
            guard let m = members[did] else { throw Fail(.notForThisDevice) }
            try certificateCheck(m, owner: card.ownerPersonID, persons: persons, now: now)
            let sealed = try Self.sealedShape(xo["sealed"])
            if let old = workspaces[ws]?.cardKeys[did]?[UInt32(seq)], old != sealed { throw Fail(.wrapConflict) }
            out.append(WrapInsert(device: did, cardSeq: UInt32(seq), sealed: sealed))
        }
        return out
    }

    /// P3-D7 atomic membership publication (members.py `publish`): an exact-body retry answers its committed result first; then the
    /// signed list (shape, workspace, sequence and epoch rules), every grant (signature, field set, this workspace, a member at this
    /// epoch, once each, sealed framing, `grant_conflict`), every member's certificate and grant, the persons rules, the wraps; then
    /// one write: departed devices pruned, members, `ever_*`, grants, list, rotation obligations, receipt. A refusal writes nothing.
    private func publish(_ ws: ID16, body: JSONValue, raw: Data, card: CardRow, now: Int64) throws -> [String: JSONValue] {
        guard var w = workspaces[ws] else { throw Fail(.notFound) }
        let digest = Data(SHA256.hash(data: raw))
        if let rc = w.receipts[digest], rc.acceptedMs > now - Self.receiptRetentionMs {
            return ["list_seq": .int(rc.listSeq), "epoch": .int(Int64(rc.epoch))]
        }
        guard let b = body.object, Self.exact(b, ["member_list", "grants"]) || Self.exact(b, ["member_list", "grants", "card_key_wraps"]),
              let signedList = b["member_list"] else { throw Fail(.malformed) }
        _ = try Self.verified(signedList, key: card.wsk, kind: .memberList)
        let list: MemberList
        do { list = try MemberList.verify(signedList, wsk: card.wsk) } catch { throw Fail(.malformed) }
        guard list.workspace == ws else { throw Fail(.otherWorkspace) }
        do {
            // The stored list's `wk_commit` as stored (trusted state; a list stored without one has none, and Q10 then refuses a
            // same-epoch successor as `wk_commit_changed`).
            let storedCommit = w.listJSON?.object?["o"]?.object?["wk_commit"]?.string.flatMap { B64U.decode($0, length: WKCommit.length) }
            try list.checkSequence(previous: w.hasList ? .init(listSeq: w.listSeq, epoch: w.epoch, members: Set(w.members.keys), wkCommit: storedCommit) : nil)
        } catch let r as Refusal { throw Fail(r) }
        guard let rawGrants = b["grants"]?.array else { throw Fail(.malformed) }
        let ids = Set(list.members.map(\.deviceID))
        var grants: [ID16: JSONValue] = [:]
        for g in rawGrants {
            let go = try Self.verified(g, key: card.wsk, kind: .wkGrant)
            guard Self.exact(go, Self.grantFields), let e = go["epoch"]?.int, e >= 1, e <= maxSafeInt,
                  let dev = go["device_id"]?.string.flatMap({ ID16(hex: $0) }) else { throw Fail(.malformed) }
            guard go["workspace_id"] == .string(ws.hex) else { throw Fail(.otherWorkspace) }
            guard ids.contains(dev), e == Int64(list.epoch) else { throw Fail(.notForThisDevice) }
            guard grants[dev] == nil else { throw Fail(.malformed) }
            _ = try Self.sealedShape(go["sealed"])
            if let old = w.grants[GrantKey(device: dev, epoch: list.epoch)], Self.canonical(old) != Self.canonical(g) { throw Fail(.grantConflict) }
            grants[dev] = g
        }
        let persons = Set(list.persons)
        for m in list.members {
            try certificateCheck(m, owner: card.ownerPersonID, persons: persons, now: now)
            guard grants[m.deviceID] != nil else { throw Fail(.missingGrant) }
        }
        do { try list.checkPersons(owner: card.ownerPersonID, first: !w.hasList) } catch let r as Refusal { throw Fail(r) }
        var wraps: [WrapInsert] = []
        if let cw = b["card_key_wraps"] {
            wraps = try checkWraps(ws, cw, card: card, members: Dictionary(uniqueKeysWithValues: list.members.map { ($0.deviceID, $0) }),
                                   persons: persons, now: now)
        }
        // The write, all of it or (above) nothing.
        for x in wraps where w.cardKeys[x.device]?[x.cardSeq] == nil { w.cardKeys[x.device, default: [:]][x.cardSeq] = x.sealed }
        let departed = Set(w.members.keys).subtracting(ids)
        for d in departed { w.grants = w.grants.filter { $0.key.device != d }; w.cardKeys[d] = nil }
        w.members = Dictionary(uniqueKeysWithValues: list.members.map { ($0.deviceID, MemberRow(personID: $0.personID, scopes: $0.scopes)) })
        for m in list.members {
            if w.everDevices[m.deviceID] == nil { w.everDevices[m.deviceID] = list.epoch }
            w.everPersons.insert(m.personID)
            let k = GrantKey(device: m.deviceID, epoch: list.epoch)
            if w.grants[k] == nil { w.grants[k] = grants[m.deviceID] }
        }
        w.listJSON = signedList; w.listSeq = list.listSeq; w.epoch = list.epoch
        w.rotationDue = w.rotationDue.filter { !($0.value.epoch < list.epoch && w.members[$0.key] == nil) }
        w.receipts = w.receipts.filter { $0.value.acceptedMs > now - Self.receiptRetentionMs }
        w.receipts[digest] = Receipt(listSeq: list.listSeq, epoch: list.epoch, acceptedMs: now)
        workspaces[ws] = w
        if !departed.isEmpty { boxes = boxes.filter { !($0.key.ws == ws && $0.key.device.map(departed.contains) == true) } }
        if !departed.isEmpty { exhaustRids(ws: ws, devices: Set(departed)) }
        return ["list_seq": .int(list.listSeq), "epoch": .int(Int64(list.epoch))]
    }

    // MARK: card (section 7.1, P3-D4)

    /// The relay's update rules read the stored card as stored (trusted state, not re-verified).
    static func storedHead(_ card: JSONValue) -> Card.Head? {
        guard let o = card.object?["o"]?.object, let d = card.object?["delegation"]?.object?["o"]?.object,
              let ws = o["workspace_id"]?.string.flatMap({ ID16(hex: $0) }), let owner = o["owner_person_id"]?.string.flatMap({ ID16(hex: $0) }),
              let wsk = o["wsk_pub"]?.string.flatMap({ B64U.decode($0) }).flatMap({ try? SigningPublicKey(x963: $0) }),
              let wxk = o["wxk_pub"]?.string.flatMap({ B64U.decode($0) }).flatMap({ try? AgreementPublicKey(x963: $0) }),
              let version = o["wxk_version"]?.int, version >= 0, version <= Int64(UInt32.max),
              let seq = o["card_seq"]?.int, seq >= 0, seq <= Int64(UInt32.max), let digest = VerifiedCard.digest(o) else { return nil }
        return Card.Head(workspace: ws, ownerPersonID: owner, wsk: wsk, wxk: wxk, wxkVersion: UInt32(version), cardSeq: UInt32(seq),
                         delegationObject: d, objectDigest: digest)
    }

    /// `PUT /v2/workspaces/{ws}/card` (directory.py `card_put`). `request` is nil for the in-process publication stand-in (no session,
    /// holder or address budget), which applies the same verification and update rules.
    func cardPut(_ ws: ID16?, body: JSONValue, r request: WireRequest?, now: Int64, address: String?) throws -> [String: JSONValue] {
        guard let b = body.object, Self.exact(b, ["card"]), let card = b["card"] else { throw Fail(.malformed) }
        try Self.checkSuite(card)
        try Self.checkSuite(card.object?["delegation"])
        guard let co = card.object?["o"]?.object else { throw Fail(.malformed) }
        let target = ws ?? co["workspace_id"]?.string.flatMap { ID16(hex: $0) }
        guard let target else { throw Fail(.malformed) }
        let stored = workspaces[target]?.card
        if stored != nil, let request {
            let s = try authorized(request, now: now)
            try workspaceAccess(s, target, write: true)
            try fence(request, target, now: now)
        }
        guard let owner = co["owner_person_id"]?.string.flatMap({ ID16(hex: $0) }) else { throw Fail(.malformed) }
        guard let pk = owners[owner] else { throw Fail(.otherPerson) }
        let v: VerifiedCard
        do {
            v = try Card.verify(card, ownerKey: pk)
            if let stored {
                guard let head = Self.storedHead(stored.json) else { throw Fail(.malformed) }
                try Card.checkRelayUpdate(previous: head, next: v)
            }
        } catch let r as Refusal { throw Fail(r) }
        guard v.workspace == target else { throw Fail(.otherWorkspace) }
        if let stored {
            guard Self.canonical(stored.json.object?["delegation"]) == Self.canonical(card.object?["delegation"]) else { throw Fail(.delegationChanged) }
            if Self.canonical(stored.json.object?["o"]) == Self.canonical(card.object?["o"]) { return ["card_seq": .int(Int64(v.cardSeq))] }
        }
        // The card names the relay it lives on; a relay accepts only its own origin (section 7.1 form, byte exact).
        guard v.relayURL == origin else { throw Fail(.malformed) }
        if stored == nil, let address {
            try rate("card-address", address, durationMs: Self.hourMs, cap: 10, now: now, charge: false)
            try rate("card-owner", owner.hex, durationMs: Self.hourMs, cap: 10, now: now, charge: false)
            try rate("card-address", address, durationMs: Self.hourMs, cap: 10, now: now)
            try rate("card-owner", owner.hex, durationMs: Self.hourMs, cap: 10, now: now)
        }
        workspaces[target, default: Workspace()].card = CardRow(json: card, wsk: v.wsk, ownerPersonID: v.ownerPersonID, cardSeq: v.cardSeq, verified: v)
        return ["card_seq": .int(Int64(v.cardSeq))]
    }

    // MARK: PK-only recovery (P3-D5): certificates and revocations

    /// `PUT /v2/devices/{device}` (`device` set) and `POST /v2/revocations` (directory.py `recovery`). Canonical retries and
    /// refused submissions are free; person quotas are charged only by a state change.
    func recover(body: JSONValue, raw: Data, now: Int64, device: ID16?) throws -> [String: JSONValue] {
        let revocation = device == nil
        let kind = revocation ? "revocation" : "certificate"
        guard let b = body.object, Self.exact(b, [revocation ? "record" : "cert"]), let signed = b[revocation ? "record" : "cert"] else {
            throw Fail(.malformed)
        }
        try Self.checkSuite(signed)
        guard let o = signed.object?["o"]?.object else { throw Fail(revocation ? .malformed : .certInvalid) }
        guard let person = o["person_id"]?.string.flatMap({ ID16(hex: $0) }), let did = o["device_id"]?.string.flatMap({ ID16(hex: $0) }) else {
            throw Fail(.malformed)
        }
        if let device, did != device { throw Fail(.certInvalid) }
        let receiptKey = kind + ":" + Hex.encode(SHA256.hash(data: raw))
        if recoveryReceipts[receiptKey] != nil {
            if !revocation, let row = devices[did] {
                if revocationRows[did] != nil { throw Fail(.revoked) }
                if let e = row.expiresMs, now >= e { throw Fail(.certExpired) }
            }
            return ["device_id": .string(did.hex)]
        }
        guard let pk = owners[person] else { throw Fail(.otherPerson) }
        let stored = devices[did], prior = revocationRows[did]
        var record: Revocation?, admitted: DeviceCertificate?
        if revocation {
            let identity = stored.map { DeviceCertificate.Identity(deviceID: $0.info?.deviceID ?? did, personID: $0.personID) }
            do { record = try Revocation.verify(signed, personKey: pk, cert: identity) } catch let r as Refusal { throw Fail(r) }
        } else {
            do { admitted = try context.admitCertificate(signed, ownerKey: pk, nowMs: now) } catch let r as Refusal { throw Fail(r) }
            if prior != nil { throw Fail(.revoked) }
            if let stored, Self.canonical(stored.cert.object?["o"]) != Self.canonical(.object(o)) { throw Fail(.certConflict) }
        }
        let noop = revocation ? prior.map { $0.reason == "compromised" || record!.reason != "compromised" } ?? false : stored != nil
        if noop {
            recoveryReceipts[receiptKey] = did
            return ["device_id": .string(did.hex)]
        }
        try rate(kind + "-person", person.hex, durationMs: Self.dayMs, cap: revocation ? 32 : 64, now: now, charge: false)
        if revocation, prior != nil { try rate("revocation-repeat", person.hex, durationMs: Self.dayMs, cap: 24, now: now, charge: false) }
        try rate(kind + "-person", person.hex, durationMs: Self.dayMs, cap: revocation ? 32 : 64, now: now)
        if revocation, prior != nil { try rate("revocation-repeat", person.hex, durationMs: Self.dayMs, cap: 24, now: now) }
        if let record { revoke(signed, record) }
        else if let admitted { devices[did] = DeviceRow(verified: admitted, cert: signed) }
        recoveryReceipts[receiptKey] = did
        return ["device_id": .string(did.hex)]
    }

    /// Section 19.5, after PK verification, in one step: store (or upgrade to `compromised`) with a new feed cursor; delete the
    /// device's sessions, mailboxes, grants and card-key wraps everywhere; set `rotation_due` where the current list names it.
    func revoke(_ signed: JSONValue, _ r: Revocation) {
        let did = r.deviceID
        let prior = revocationRows[did]
        var cursor = prior?.cursor ?? 0
        if prior == nil || (prior!.reason != "compromised" && r.reason == "compromised") {
            cursor = (revocationRows.values.map(\.cursor).max() ?? 0) + 1
            revocationRows[did] = RevocationRow(record: signed, personID: r.personID, reason: r.reason, cursor: cursor)
        }
        sessions = sessions.filter { !($0.value.kind == .device && $0.value.id == did) }
        for (ws, w) in workspaces {
            removeDevice(did, from: ws)
            if w.members[did] != nil { workspaces[ws]?.rotationDue[did] = RotationDue(cursor: cursor, epoch: w.epoch) }
        }
    }

    /// `GET /v2/persons/{person}/revocations` (D(p) or W, filtered by `ever_devices` before pagination).
    private func feed(_ s: Session, person: ID16, q: [String: String]) throws -> [String: JSONValue] {
        try personAccess(s, person)
        guard let after0 = HostAPI.parseDecimal(q["after"] ?? "0"), after0 <= UInt64(maxSafeInt),
              let limit = HostAPI.parseDecimal(q["limit"] ?? "256"), limit >= 1, limit <= 256 else { throw Fail(.malformed) }
        var after = Int64(after0)
        if let next = q["next"] {
            guard let raw = B64U.decode(next), let c = (try? StrictJSON.parse(raw, maxBytes: 1024))?.object, Self.exact(c, ["person", "after", "cursor"]),
                  c["person"] == .string(person.hex), c["after"] == .int(after), let cursor = c["cursor"]?.int, cursor >= 0 else { throw Fail(.malformed) }
            after = cursor
        }
        let filter = s.kind == .workspace ? workspaces[s.id]?.everDevices : nil
        let rows = revocationRows.filter { $0.value.personID == person && $0.value.cursor > after && $0.value.record != .null
            && (s.kind == .device || filter?[$0.key] != nil) }.map(\.value).sorted { $0.cursor < $1.cursor }
        var entries: [JSONValue] = [], size = 0
        for row in rows.prefix(Int(limit)) {
            let item: JSONValue = ["cursor": .int(row.cursor), "record": row.record]
            let n = ((try? canonicalJSON(item))?.count ?? 0) + 1
            if size + n > (4 << 20) - 1024 { break }
            entries.append(item); size += n
        }
        var next: JSONValue = .null
        if entries.count < rows.count, let last = entries.last?.object?["cursor"] {
            next = .string(B64U.encode(try canonicalJSON(["person": .string(person.hex), "after": .int(Int64(after0)), "cursor": last])))
        }
        return ["revocations": .array(entries), "next": next]
    }
}
