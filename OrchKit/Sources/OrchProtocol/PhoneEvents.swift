import CryptoKit
import Foundation

/// ULID (Crockford base32, 26 characters): 48-bit big-endian millisecond time, then 80 random bits. The first character is 0...7.
/// Host section 11A.14 14.1: `^[0-7][0-9A-HJKMNP-TV-Z]{25}$`. The phone makes the event id (and the creation's ticket uid) itself.
public enum ULID {
    public enum Failure: Error, Equatable, Sendable { case timeOutOfRange, badRandomLength }

    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)
    public static let randomLength = 10

    /// `timeMs` must fit 48 bits; `random` is exactly 10 bytes from the OS CSPRNG (the caller owns the entropy source).
    public static func make(timeMs: Int64, random: Data) throws -> String {
        guard timeMs >= 0, timeMs < (1 << 48) else { throw Failure.timeOutOfRange }
        guard random.count == randomLength else { throw Failure.badRandomLength }
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<6 { bytes[i] = UInt8((timeMs >> Int64(8 * (5 - i))) & 0xFF) }
        for (i, b) in random.enumerated() { bytes[6 + i] = b }
        // 128 bits as 26 groups of 5 bits, the first group carrying only the top 3 bits
        var out = [UInt8]()
        // left-pad with two zero bits so that the 128 bits become 130
        var acc: UInt32 = 0, bits = 2
        for b in bytes {
            acc = (acc << 8) | UInt32(b); bits += 8
            while bits >= 5 {
                out.append(alphabet[Int((acc >> UInt32(bits - 5)) & 31)])
                bits -= 5
            }
            acc &= (1 << UInt32(bits)) - 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    public static func isValid(_ s: String) -> Bool { F1ASCII.isULID(s) }

    /// The 48-bit millisecond time of a valid ULID.
    public static func timeMs(of s: String) -> Int64? {
        guard isValid(s) else { return nil }
        var v: Int64 = 0
        for c in s.utf8.prefix(10) { v = (v << 5) | Int64(alphabet.firstIndex(of: c)!) }
        return v
    }

    /// The window the host admits a never-seen event id in (14.4): `[host now - 900 s, host now + 300 s]`.
    public static let windowPastMs: Int64 = 900_000
    public static let windowFutureMs: Int64 = 300_000
    /// The phone sends no outbox item older than 840 s; it re-reviews (14.4).
    public static let outboxMaxAgeMs: Int64 = 840_000

    public static func isInsideHostWindow(_ id: String, hostNowMs: Int64) -> Bool {
        guard let t = timeMs(of: id) else { return false }
        return t >= saturatingAdd(hostNowMs, -windowPastMs) && t <= saturatingAdd(hostNowMs, windowFutureMs)
    }
}

/// Who signs: the phone's certificate identity and its custody (14.1, 14.3).
public struct PhoneActor: Equatable, Sendable {
    public let personID: String
    public let deviceID: String
    /// `secure-enclave-unlocked` on a device; `passphrase` only in Simulator/dev builds. Column R accepts exactly these two.
    public let auth: F1Auth

    public init(person: ID16, device: ID16, auth: F1Auth) throws {
        guard auth == .secureEnclaveUnlocked || auth == .passphrase else { throw Refusal.malformed }
        personID = "p_" + person.hex; deviceID = "d_" + device.hex; self.auth = auth
    }
}

/// A signed person event ready for `relay.submit` (host section 11A.14 14.1, 14.2). `bytes` is `cj(event)` with `sig`.
public struct SignedPhoneEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case questionAnswered, ticketCreated }
    public let kind: Kind
    public let log: String
    /// The event id: also `opts.idem` (idem = event id, 14.4).
    public let id: String
    public let event: [String: JSONValue]
    /// `cj(event)`, the submitted form (no seq, at, prev, ws_seq, host_sig).
    public let bytes: Data
    /// `"orch/v2/sig/ticket-event|" || cj({contract, event: E, log, suite, workspace_id})`.
    public let signingBytes: Data
    /// The signed-content digest `sha256:` + hex(sha256(signingBytes)), the host's dedup identity (14.4).
    public let digest: String
    public let signature: Data
}

/// Builds and signs the two phone person events. The result depends only on its inputs (the id, the snapshot values and the signer).
public enum PhoneEvents {
    public static let maxAnswerTextBytes = 4096
    public static let maxTitleScalars = 200
    public static let ticketTypes = ["feature", "bug", "chore", "spike", "epic"]

    /// Phone-authored text that went through `prepareText`: the only way to build the `text` of an answer or the `title` of a creation.
    /// Normalised (LF, NFC under Unicode 16.0) and checked against section 11.3 already, so the sign sheet shows exactly what is signed.
    public struct PreparedText: Equatable, Sendable {
        public let value: String
        public let oneLine: Bool
        fileprivate init(value: String, oneLine: Bool) { self.value = value; self.oneLine = oneLine }
    }

    public enum Failure: Error, Equatable, Sendable {
        case badID, badTicketUID, badRoster, badBase, notOpen, unknownOption, noAnswer
        case text(F1Text.Violation), textTooLong, emptyText, titleLength
        case badKey, badType
        /// `validateSigned`: a field set, type or value outside P1 to P5.
        case schema(String)
        /// `validateSigned`: a host-assigned field (`seq`, `at`, `prev`, `ws_seq`, `host_sig`) on a phone event.
        case hostField(String)
        /// `validateSigned` P4: the actor or `auth` is not the one this device signs as.
        case actorMismatch
        /// `validateSigned`: `sig` does not verify under the device key over the recomputed signing bytes.
        case badSignature
        /// `validateSigned`: a cached field (`bytes`, `signingBytes`, `digest`, `signature`, `id`, `log`) disagrees with the event.
        case inconsistent(String)
    }

    /// An event as the phone would sign it, with every field the signature covers and no `sig`: what `AutoResign.decide` compares before a
    /// key is used. Only `unsignedAnswer` / `unsignedCreate` build one, and only `sign` turns it into a `SignedPhoneEvent`.
    public struct UnsignedPhoneEvent: Equatable, Sendable {
        public let kind: SignedPhoneEvent.Kind
        public let log: String
        public let id: String
        /// The event without `sig`.
        public let event: [String: JSONValue]
        public let workspace: ID16
        fileprivate init(kind: SignedPhoneEvent.Kind, log: String, id: String, event: [String: JSONValue], workspace: ID16) {
            self.kind = kind; self.log = log; self.id = id; self.event = event; self.workspace = workspace
        }
    }

    /// Phone-authored text (title, free-text answer) to be shown on the sign sheet and signed: CRLF/CR to LF, NFC (Unicode 16.0), checks.
    public static func prepareText(_ s: String, oneLine: Bool) throws -> PreparedText {
        do { return PreparedText(value: try F1Text.normalize(s, oneLine: oneLine), oneLine: oneLine) } catch let v as F1Text.Violation { throw Failure.text(v) }
    }

    // MARK: question.answered

    /// `question.answered` (F1 section 5.4.1): exact fields `question`, `hash`, then `option?` and/or `text?`. `basedOn` is
    /// `ticket.get` -> `doc.head.head`, `rosterV` is `members_v`. `reviewed` must come from `F1Question.reviewed` (recomputed hash).
    package static func answer(_ r: F1Question.Reviewed, option: String?, text: PreparedText?, id: String,
                               actor: PhoneActor, workspace: ID16, signer: some Signer) throws -> SignedPhoneEvent {
        try sign(try unsignedAnswer(r, option: option, text: text, id: id, actor: actor, workspace: workspace), signer: signer)
    }

    /// The unsigned `question.answered` (same checks as `answer`), for the auto re-sign decision and for `sign`.
    package static func unsignedAnswer(_ r: F1Question.Reviewed, option: String?, text: PreparedText?, id: String,
                                       actor: PhoneActor, workspace: ID16) throws -> UnsignedPhoneEvent {
        guard ULID.isValid(id) else { throw Failure.badID }
        guard r.question.state == .open else { throw Failure.notOpen }
        guard option != nil || text != nil else { throw Failure.noAnswer }
        var e: [String: JSONValue] = envelope(actor: actor, id: id, rosterV: r.rosterV, type: "question.answered", basedOn: .string(r.basedOn))
        e["question"] = .string(r.question.id)
        e["hash"] = .string(r.hash)
        if let option {
            guard let match = r.question.options.first(where: { $0.key.bytesEqual(option) }) else { throw Failure.unknownOption }
            e["option"] = .string(match.key)
        }
        if let text {
            guard !text.value.isEmpty else { throw Failure.emptyText }
            guard text.value.utf8.count <= maxAnswerTextBytes else { throw Failure.textTooLong }
            e["text"] = .string(text.value)
        }
        return UnsignedPhoneEvent(kind: .questionAnswered, log: r.ticketUID, id: id, event: e, workspace: workspace)
    }

    // MARK: ticket.created

    /// `ticket.created` (title-only, R2): exact fields `key`, `ticket_type`, `title`, `owner`; `based_on` null; log = the new ticket's
    /// `uid`, made once per review. `key` is `workspace.show` -> `next_key`.
    package static func create(ticketUID: String, key: String, ticketType: String, title: PreparedText, id: String, rosterV: Int64,
                               actor: PhoneActor, workspace: ID16, signer: some Signer) throws -> SignedPhoneEvent {
        try sign(try unsignedCreate(ticketUID: ticketUID, key: key, ticketType: ticketType, title: title, id: id, rosterV: rosterV,
                                    actor: actor, workspace: workspace), signer: signer)
    }

    /// The unsigned `ticket.created` (same checks as `create`).
    package static func unsignedCreate(ticketUID: String, key: String, ticketType: String, title: PreparedText, id: String, rosterV: Int64,
                                       actor: PhoneActor, workspace: ID16) throws -> UnsignedPhoneEvent {
        guard ULID.isValid(id) else { throw Failure.badID }
        guard ULID.isValid(ticketUID) else { throw Failure.badTicketUID }
        guard rosterV >= 0, rosterV <= maxSafeInt else { throw Failure.badRoster }
        guard F1ASCII.isTicketKey(key) else { throw Failure.badKey }
        guard let type = F1ASCII.oneOf(ticketType, ticketTypes) else { throw Failure.badType }
        guard title.oneLine else { throw Failure.titleLength }
        let n = title.value.unicodeScalars.count
        guard n >= 1, n <= maxTitleScalars else { throw Failure.titleLength }
        var e: [String: JSONValue] = envelope(actor: actor, id: id, rosterV: rosterV, type: "ticket.created", basedOn: .null)
        e["key"] = .string(key)
        e["ticket_type"] = .string(type)
        e["title"] = .string(title.value)
        e["owner"] = .string(actor.personID)
        return UnsignedPhoneEvent(kind: .ticketCreated, log: ticketUID, id: id, event: e, workspace: workspace)
    }

    // MARK: signing

    private static func envelope(actor: PhoneActor, id: String, rosterV: Int64, type: String, basedOn: JSONValue) -> [String: JSONValue] {
        ["v": 2, "hash_v": 1, "id": .string(id), "type": .string(type),
         "actor": ["kind": "person", "id": .string(actor.personID), "device": .string(actor.deviceID)],
         "auth": .string(actor.auth.rawValue), "roster_v": .int(rosterV), "based_on": basedOn]
    }

    /// `"orch/v2/sig/ticket-event|" || cj({"contract":1, "event":E, "log":uid, "suite":2, "workspace_id":W})`, E without `sig`.
    public static func signingBytes(event: [String: JSONValue], log: String, workspace: ID16) throws -> Data {
        // core refuses the ticket-event label with log "workspace" (workspace events sign under ws-event)
        guard ULID.isValid(log) else { throw Failure.badTicketUID }
        let body = try canonicalJSON(["contract": 1, "event": .object(event), "log": .string(log), "suite": 2, "workspace_id": .string(workspace.hex)])
        return Data(Label.sigTicketEvent.utf8) + body
    }

    /// `sha256:` + hex(sha256(signing bytes)): the host's content identity of a signed event (14.4).
    public static func digest(signingBytes: Data) -> String { "sha256:" + Hex.encode(SHA256.hash(data: signingBytes)) }

    /// Signs an unsigned event with the device key (`orch/v2/sig/ticket-event`). The only way to a `SignedPhoneEvent`.
    package static func sign(_ u: UnsignedPhoneEvent, signer: some Signer) throws -> SignedPhoneEvent {
        let bytes = try signingBytes(event: u.event, log: u.log, workspace: u.workspace)
        let label = Label.sigTicketEvent
        let sig = try Signature.sign(signer, label: label, message: Data(bytes.dropFirst(label.utf8.count)))
        var signed = u.event
        signed["sig"] = .string(B64U.encode(sig))
        let wire = try canonicalJSON(.object(signed))
        return SignedPhoneEvent(kind: u.kind, log: u.log, id: u.id, event: signed, bytes: wire, signingBytes: bytes,
                                digest: digest(signingBytes: bytes), signature: sig)
    }

    // MARK: validation

    static let hostFields: Set<String> = ["seq", "at", "prev", "ws_seq", "host_sig"]

    /// Everything a signed phone event must satisfy before it is framed (host section 11A.14 14.6 P1 to P5, plus the signature): the exact
    /// field set with no host field, `v` 2 and `hash_v` 1, the type of `kind`, valid id and log, a creation's `based_on` null, F1 text rules,
    /// P4 (`actor` is exactly `{person, actor.personID, actor.deviceID}` and `auth` is `actor.auth`), then `sig` against the signing bytes
    /// RECOMPUTED here from the event without `sig`, and every cached field of `e` (`bytes`, `signingBytes`, `digest`, `signature`, `id`,
    /// `log`) against that recomputation. Nothing the caller cached is trusted.
    public static func validateSigned(_ e: SignedPhoneEvent, kind: SignedPhoneEvent.Kind, actor: PhoneActor, workspace: ID16,
                                      pub: SigningPublicKey) throws {
        guard e.kind == kind else { throw Failure.schema("kind") }
        let ev = e.event
        if let h = ev.keys.sorted().first(where: { hostFields.contains($0) }) { throw Failure.hostField(h) }
        let common: Set<String> = ["v", "hash_v", "id", "type", "actor", "auth", "roster_v", "based_on", "sig"]
        let type: String
        switch kind {
        case .questionAnswered:
            type = "question.answered"
            let keys = Set(ev.keys)
            let required = common.union(["question", "hash"])
            guard keys.isSuperset(of: required), keys.isSubset(of: required.union(["option", "text"])) else { throw Failure.schema("fields") }
            guard ev["option"] != nil || ev["text"] != nil else { throw Failure.schema("answer") }
        case .ticketCreated:
            type = "ticket.created"
            guard Set(ev.keys) == common.union(["key", "ticket_type", "title", "owner"]) else { throw Failure.schema("fields") }
        }
        guard ev["v"]?.int == 2, ev["hash_v"]?.int == 1 else { throw Failure.schema("version") }
        guard let t = ev["type"]?.string, t.bytesEqual(type) else { throw Failure.schema("type") }
        guard let id = ev["id"]?.string, ULID.isValid(id) else { throw Failure.badID }
        guard ULID.isValid(e.log) else { throw Failure.badTicketUID }
        guard let roster = ev["roster_v"]?.int, roster >= 0, roster <= maxSafeInt else { throw Failure.badRoster }
        // P4
        guard let a = ev["actor"]?.object, Set(a.keys) == ["kind", "id", "device"],
              a["kind"]?.string?.bytesEqual("person") == true, a["id"]?.string?.bytesEqual(actor.personID) == true,
              a["device"]?.string?.bytesEqual(actor.deviceID) == true,
              ev["auth"]?.string?.bytesEqual(actor.auth.rawValue) == true else { throw Failure.actorMismatch }
        switch kind {
        case .questionAnswered:
            guard let q = ev["question"]?.string, F1ASCII.isQuestionID(q) else { throw Failure.schema("question") }
            guard let h = ev["hash"]?.string, F1ASCII.isHash(h) else { throw Failure.schema("hash") }
            guard let b = ev["based_on"]?.string, F1ASCII.isHash(b) else { throw Failure.badBase }
            if let o = ev["option"] { guard let s = o.string, !s.isEmpty else { throw Failure.schema("option") } }
            if let tx = ev["text"] {
                guard let s = tx.string else { throw Failure.schema("text") }
                guard !s.isEmpty else { throw Failure.emptyText }
                guard s.utf8.count <= maxAnswerTextBytes else { throw Failure.textTooLong }
                do { try F1Text.check(s) } catch let v as F1Text.Violation { throw Failure.text(v) }
            }
        case .ticketCreated:
            guard ev["based_on"] == .null else { throw Failure.badBase }
            guard let k = ev["key"]?.string, F1ASCII.isTicketKey(k) else { throw Failure.badKey }
            guard let tt = ev["ticket_type"]?.string, F1ASCII.oneOf(tt, ticketTypes) != nil else { throw Failure.badType }
            guard let title = ev["title"]?.string else { throw Failure.schema("title") }
            let n = title.unicodeScalars.count
            guard n >= 1, n <= maxTitleScalars else { throw Failure.titleLength }
            do { try F1Text.check(title, oneLine: true) } catch let v as F1Text.Violation { throw Failure.text(v) }
            guard ev["owner"]?.string?.bytesEqual(actor.personID) == true else { throw Failure.actorMismatch }
        }
        // the signature, over bytes recomputed from the event itself
        guard let sigText = ev["sig"]?.string, let sig = B64U.decode(sigText, length: Suite2.signatureLength) else { throw Failure.schema("sig") }
        var unsigned = ev; unsigned["sig"] = nil
        let bytes = try signingBytes(event: unsigned, log: e.log, workspace: workspace)
        let label = Label.sigTicketEvent
        guard Signature.verify(pub, signature: sig, label: label, message: Data(bytes.dropFirst(label.utf8.count))) else { throw Failure.badSignature }
        guard e.id.bytesEqual(id) else { throw Failure.inconsistent("id") }
        guard e.signature == sig else { throw Failure.inconsistent("signature") }
        guard e.signingBytes == bytes else { throw Failure.inconsistent("signingBytes") }
        guard e.digest.bytesEqual(digest(signingBytes: bytes)) else { throw Failure.inconsistent("digest") }
        guard e.bytes == (try canonicalJSON(.object(ev))) else { throw Failure.inconsistent("bytes") }
    }
}
