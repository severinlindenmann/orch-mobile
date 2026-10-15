import CryptoKit
import Foundation

/// ULID (Crockford base32, 26 characters): 48-bit big-endian millisecond time, then 80 random bits. The first character is 0...7.
/// Host section 11A.14 14.1: `^[0-7][0-9A-HJKMNP-TV-Z]{25}$`. The phone makes the event id (and the creation's ticket uid) itself.
public enum ULID {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)
    public static let randomLength = 10

    /// `timeMs` must fit 48 bits; `random` is exactly 10 bytes from the OS CSPRNG (the caller owns the entropy source).
    public static func make(timeMs: Int64, random: Data) throws -> String {
        guard timeMs >= 0, timeMs < (1 << 48), random.count == randomLength else { throw CryptoFailure.invalidLength }
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<6 { bytes[i] = UInt8((timeMs >> Int64(8 * (5 - i))) & 0xFF) }
        for (i, b) in random.enumerated() { bytes[6 + i] = b }
        // 128 bits as 26 groups of 5 bits, the first group carrying only the top 3 bits
        var out = [UInt8]()
        var acc: UInt32 = 0, bits = 0
        // left-pad with two zero bits so that the 128 bits become 130
        acc = 0; bits = 2
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
        return t >= hostNowMs - windowPastMs && t <= hostNowMs + windowFutureMs
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

    public enum Failure: Error, Equatable, Sendable {
        case badID, badTicketUID, badRoster, badBase, badQuestion, notOpen, unknownOption, noAnswer
        case text(F1Text.Violation), textTooLong, emptyText, titleLength
        case badKey, badType
    }

    /// Phone-authored text (title, free-text answer) to be shown on the sign sheet and signed: CRLF/CR to LF, NFC (Unicode 16.0), checks.
    public static func prepareText(_ s: String, oneLine: Bool) throws -> String {
        do { return try F1Text.normalize(s, oneLine: oneLine) } catch let v as F1Text.Violation { throw Failure.text(v) }
    }

    // MARK: question.answered

    /// `question.answered` (F1 section 5.4.1): exact fields `question`, `hash`, then `option?` and/or `text?`. `basedOn` is
    /// `ticket.get` -> `doc.head.head`, `rosterV` is `members_v`. `reviewed` must come from `F1Question.reviewed` (recomputed hash).
    package static func answer(_ r: F1Question.Reviewed, option: String?, text: String?, id: String, basedOn: String, rosterV: Int64,
                               actor: PhoneActor, workspace: ID16, signer: some Signer) throws -> SignedPhoneEvent {
        guard ULID.isValid(id) else { throw Failure.badID }
        guard F1ASCII.isHash(basedOn) else { throw Failure.badBase }
        guard rosterV >= 0, rosterV <= maxSafeInt else { throw Failure.badRoster }
        guard r.question.state == .open else { throw Failure.notOpen }
        guard option != nil || text != nil else { throw Failure.noAnswer }
        var e: [String: JSONValue] = envelope(actor: actor, id: id, rosterV: rosterV, type: "question.answered", basedOn: .string(basedOn))
        e["question"] = .string(r.question.id)
        e["hash"] = .string(r.hash)
        if let option {
            guard let match = r.question.options.first(where: { $0.key.bytesEqual(option) }) else { throw Failure.unknownOption }
            e["option"] = .string(match.key)
        }
        if let text {
            guard !text.isEmpty else { throw Failure.emptyText }
            do { try F1Text.check(text) } catch let v as F1Text.Violation { throw Failure.text(v) }
            guard text.utf8.count <= maxAnswerTextBytes else { throw Failure.textTooLong }
            e["text"] = .string(text)
        }
        return try sign(e, kind: .questionAnswered, log: r.ticketUID, workspace: workspace, signer: signer)
    }

    // MARK: ticket.created

    /// `ticket.created` (title-only, R2): exact fields `key`, `ticket_type`, `title`, `owner`; `based_on` null; log = the new ticket's
    /// `uid`, made once per review. `key` is `workspace.show` -> `next_key`.
    package static func create(ticketUID: String, key: String, ticketType: String, title: String, id: String, rosterV: Int64,
                               actor: PhoneActor, workspace: ID16, signer: some Signer) throws -> SignedPhoneEvent {
        guard ULID.isValid(id) else { throw Failure.badID }
        guard ULID.isValid(ticketUID) else { throw Failure.badTicketUID }
        guard rosterV >= 0, rosterV <= maxSafeInt else { throw Failure.badRoster }
        guard F1ASCII.isTicketKey(key) else { throw Failure.badKey }
        guard let type = F1ASCII.oneOf(ticketType, ticketTypes) else { throw Failure.badType }
        do { try F1Text.check(title, oneLine: true) } catch let v as F1Text.Violation { throw Failure.text(v) }
        let n = title.unicodeScalars.count
        guard n >= 1, n <= maxTitleScalars else { throw Failure.titleLength }
        var e: [String: JSONValue] = envelope(actor: actor, id: id, rosterV: rosterV, type: "ticket.created", basedOn: .null)
        e["key"] = .string(key)
        e["ticket_type"] = .string(type)
        e["title"] = .string(title)
        e["owner"] = .string(actor.personID)
        return try sign(e, kind: .ticketCreated, log: ticketUID, workspace: workspace, signer: signer)
    }

    // MARK: signing

    private static func envelope(actor: PhoneActor, id: String, rosterV: Int64, type: String, basedOn: JSONValue) -> [String: JSONValue] {
        ["v": 2, "hash_v": 1, "id": .string(id), "type": .string(type),
         "actor": ["kind": "person", "id": .string(actor.personID), "device": .string(actor.deviceID)],
         "auth": .string(actor.auth.rawValue), "roster_v": .int(rosterV), "based_on": basedOn]
    }

    /// `"orch/v2/sig/ticket-event|" || cj({"contract":1, "event":E, "log":uid, "suite":2, "workspace_id":W})`, E without `sig`.
    public static func signingBytes(event: [String: JSONValue], log: String, workspace: ID16) throws -> Data {
        let body = try canonicalJSON(["contract": 1, "event": .object(event), "log": .string(log), "suite": 2, "workspace_id": .string(workspace.hex)])
        return Data(Label.sigTicketEvent.utf8) + body
    }

    /// `sha256:` + hex(sha256(signing bytes)): the host's content identity of a signed event (14.4).
    public static func digest(signingBytes: Data) -> String { "sha256:" + Hex.encode(SHA256.hash(data: signingBytes)) }

    private static func sign(_ unsigned: [String: JSONValue], kind: SignedPhoneEvent.Kind, log: String, workspace: ID16,
                             signer: some Signer) throws -> SignedPhoneEvent {
        let bytes = try signingBytes(event: unsigned, log: log, workspace: workspace)
        let label = Label.sigTicketEvent
        let sig = try Signature.sign(signer, label: label, message: Data(bytes.dropFirst(label.utf8.count)))
        var signed = unsigned
        signed["sig"] = .string(B64U.encode(sig))
        let wire = try canonicalJSON(.object(signed))
        guard let id = unsigned["id"]?.string else { throw Failure.badID }
        return SignedPhoneEvent(kind: kind, log: log, id: id, event: signed, bytes: wire, signingBytes: bytes,
                                digest: digest(signingBytes: bytes), signature: sig)
    }
}
