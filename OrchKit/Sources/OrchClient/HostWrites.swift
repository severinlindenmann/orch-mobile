import Foundation
import OrchProtocol

/// Phone writes over column R (C2b): the request meta of a signed person event and the check of the host's answer to it. Nothing here
/// signs, seals or sends: sealing and posting stay in `WorkspaceSession`, behind its write gate.

public enum HostWriteError: Error, Equatable, Sendable {
    /// The event's type is not the one event type of the op its kind maps to (`answer` <-> `question.answered`, `new_ticket` <-> `ticket.created`).
    case opMismatch
    /// `idem` is not the event id, or `log` is not the one the event was signed under.
    case idemMismatch
    case logMismatch
    /// The event did not carry exactly its own fields.
    case malformedEvent
}

extension R2 {
    /// The op a signed phone event is submitted under.
    public static func writeOp(for kind: SignedPhoneEvent.Kind) -> String {
        switch kind {
        case .questionAnswered: "answer"
        case .ticketCreated: "new_ticket"
        }
    }

    /// The ONE builder of a write's meta: `{"op", "args":{"log", "events":[E]}, "idem":E.id}` (`rd` is added at the session's single
    /// injection point, `ReaderRD.inject`). `E` is the signed event exactly as signed. It checks op against event type, `idem` against the
    /// event id, `log` against the event's log and that there is exactly one event, then the host's own meta checks (`checkMeta`).
    public static func writeMeta(_ e: SignedPhoneEvent) throws -> JSONValue {
        let op = writeOp(for: e.kind)
        guard let spec = ops[op], spec.kind == .write, let type = e.event["type"]?.string, let want = spec.event, type.bytesEqual(want) else { throw HostWriteError.opMismatch }
        guard let id = e.event["id"]?.string, id.bytesEqual(e.id), ULID.isValid(id) else { throw HostWriteError.idemMismatch }
        guard ULID.isValid(e.log) else { throw HostWriteError.logMismatch }
        guard e.event["sig"]?.string != nil else { throw HostWriteError.malformedEvent }
        let meta = try requestMeta(op: op, args: ["log": .string(e.log), "events": .array([.object(e.event)])], idem: id)
        let checked = try checkMeta(meta)
        guard checked.idem?.bytesEqual(e.id) == true, checked.args["events"]?.array?.count == 1, Set(checked.args.keys) == ["log", "events"],
              checked.args["log"]?.string?.bytesEqual(e.log) == true else { throw HostWriteError.malformedEvent }
        return meta
    }
}

/// The host's success answer to a write: `data` exactly `{log, seqs:[n]}` (orch-52 Q8), `log` the one the event was signed under, one
/// landed seq (>= 1) and `exit` 0. Anything else is not evidence of a landing.
public struct WriteResult: Equatable, Sendable {
    public let log: String
    public let seq: Int64
    /// The host's `duplicate` flag: the same event was already there (still a landing).
    public let duplicate: Bool

    public init(parsing r: HostResult, expecting e: SignedPhoneEvent) throws {
        guard r.exit == 0, let d = r.data.object, Set(d.keys) == ["log", "seqs"],
              let log = d["log"]?.string, log.bytesEqual(e.log),
              let seqs = d["seqs"]?.array, seqs.count == 1, let n = seqs[0].int, n >= 1, n <= maxSafeInt else { throw ViewError.malformed }
        self.log = log; self.seq = n; self.duplicate = r.duplicate
    }

    /// A `Result` nested in `outcome.get` (`result`), as a JSON value.
    public init(parsing v: JSONValue, expecting e: SignedPhoneEvent) throws {
        try self.init(parsing: try HostResult(parsing: try canonicalJSON(v)), expecting: e)
    }
}
