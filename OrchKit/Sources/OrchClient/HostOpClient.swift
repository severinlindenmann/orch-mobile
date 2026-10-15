import Foundation
import OrchProtocol

/// The phone's op client over column R (host 11A.5): every call is one sealed bridge request built by `R2.requestMeta`, answered by a
/// Result or a refusal, and parsed into a typed result of `HostReads`. Reads take no `idem` and are idempotent, so the retry classes of a
/// READ are simple (11A.5 "Retry classes"):
/// - A (`busy`, `store.busy`, `lock.busy`, `rate.limited`, `quota.host`, `host.restarting`, `conn.overloaded`, a stale answer the session
///   already re-signs): nothing ran, so the read is sent again after a short wait, at most `maxBusyRetries` times;
/// - B (`already_done {status: unknown}`, `rid_conflict`): something may have run, and a read has no effect to reconcile, so it is issued
///   again under a NEW rid, at most `maxReissues` times;
/// - C and D are definite: the refusal is the answer.
extension WorkspaceSession {
    static var maxReissues: Int { 2 }
    static var maxBusyRetries: Int { 3 }
    /// At most one fresh declaration per this long after a `declaration_unknown` (a host that keeps saying it must not make the phone sign
    /// declarations without end).
    static var redeclareMinInterval: Duration { .seconds(300) }

    /// The ONE exit for every read: whatever fails (a snapshot step, the poller's feed read, a question read) goes through `noteReadFailure`
    /// (identity caches dropped; a reader refusal also ends the cached view and is announced), and every attempt row of the read is
    /// discarded whatever the outcome (a read leaves nothing to settle).
    package func callRead(_ op: String, args: [String: JSONValue] = [:]) async throws -> HostResult {
        do { return try await attemptRead(op, args: args) } catch { noteReadFailure(error); throw error }
    }

    private func attemptRead(_ op: String, args: [String: JSONValue]) async throws -> HostResult {
        guard let spec = R2.allOps[op], spec.kind == .read else { throw R2.MetaError.forbiddenScope }
        var reissues = 0, busy = 0
        while true {
            try Task.checkCancellation()
            let plaintext = try Bridge.frame(meta: try R2.requestMeta(op: op, args: args))
            let logical = cfg.entropy.id16()
            let outcome: Result<HostResult, Error>
            do {
                let first = try await prepare(logical: logical, plaintext: plaintext)
                outcome = .success(try Self.result(of: try await runDriver(first, isResend: false)))
            } catch { outcome = .failure(error) }
            await discardRead(logical: logical)
            switch outcome {
            case .success(let r): return r
            case .failure(SessionError.uncertain(let l)):
                // B on a read: re-issue under a new rid, never re-sent
                reissues += 1
                guard reissues <= Self.maxReissues else { throw SessionError.uncertain(logical: l) }
            case .failure(ClientError.host(.reader(let code, "declaration_unknown", _, _))) where code == "sign.convenience_readers" && op != "reader.declare":
                // H12d-3: the host does not hold the declaration `rd` names. Declare again (a read, exempt from `rd`), take the digest of the
                // answer, and send the ORIGINAL request under a new rid, once, and at most once per `redeclareMinInterval`. If this build
                // can declare nothing, or declared recently, the refusal stands: re-pair or update.
                guard redeclareAllowed() else { throw ClientError.host(.reader(code: code, reason: "declaration_unknown", required: nil, declared: nil)) }
                noteRedeclare()
                guard try await declareReader(force: true) else { throw ClientError.host(.reader(code: code, reason: "declaration_unknown", required: nil, declared: nil)) }
            case .failure(ClientError.host(let refusal)) where R2.retryClass(of: refusal) == .a && busy < Self.maxBusyRetries:
                try await cfg.clock.sleep(for: .seconds(1 << busy))
                busy += 1
            case .failure(let e): throw e
            }
        }
    }

    /// An R2 success answer: status 200 (the first chunk's `{"status":"ok"}`), no headers, `cj(Result)` with `exit` 0.
    static func result(of response: BridgeResponse) throws -> HostResult {
        // R2 framing only: a v0 `{status, headers}` first chunk is not an answer to a column-R read, whatever its status
        guard response.r2, response.status == 200, response.headers.isEmpty else { throw ViewError.malformed }
        let r = try HostResult(parsing: response.data)
        guard r.exit == 0 else { throw ViewError.malformed }
        return r
    }

    package func needs() async throws -> NeedsResult { try NeedsResult(try await callRead("needs").data) }
    package func ticketQuery(limit: Int = 200, page: String? = nil) async throws -> TicketPage {
        var args: [String: JSONValue] = ["limit": .int(Int64(limit)), "sort": "updated", "order": "desc"]
        if let page { args["page"] = .string(page) }
        return try TicketPage(try await callRead("ticket.query", args: args).data)
    }
    package func ticketGet(_ ref: String) async throws -> TicketGet {
        try TicketGet(try await callRead("ticket.get", args: ["ref": .string(ref), "log_limit": 1]).data)
    }
    package func memberList() async throws -> MemberListResult { try MemberListResult(try await callRead("member.list").data) }
    package func workspaceShow() async throws -> WorkspaceShowResult { try WorkspaceShowResult(try await callRead("workspace.show").data) }
    package func activityList(limit: Int = 50, types: [String]? = nil, page: String? = nil) async throws -> ActivityPage {
        var args: [String: JSONValue] = ["limit": .int(Int64(limit))]
        if let types { args["types"] = .array(types.map(JSONValue.string)) }
        if let page { args["page"] = .string(page) }
        return try ActivityPage(try await callRead("activity.list", args: args).data)
    }
    package func whoami() async throws -> WhoAmIResult { try WhoAmIResult(try await callRead("whoami").data) }
    package func outcomeGet(idem: String) async throws -> OutcomeResult {
        try OutcomeResult(try await callRead("outcome.get", args: ["idem": .string(idem)]).data)
    }
}
