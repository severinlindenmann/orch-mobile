import Foundation
import OrchCustody
import OrchProtocol

// Custodial signing from the phone (design B3, orch-hub protocol 8.2 to 8.5). One actor, one path:
//
//   prepare / open  ->  allow-list  ->  check_prepared (digest recomputed from ctx)  ->  check_built (self-started)  ->  phone bindings
//                   ->  facts from ctx  ->  [the person reads the prompt]  ->  confirm: still live? -> Face ID -> proof -> POST /sign/sign
//
// Invariants: the phone renders ONLY from `ctx` (the hub's `shown` is never read); there is no Confirm for any type outside the four
// decisions; the proof is made over a digest this actor computed from the `ctx` it holds, in the same instance that rendered it (the
// pending requests live in memory only); a proof is made only while the hub answers and the prepared id is live; nothing is queued, retried
// or re-prepared on its own; every failure says "Nothing was signed", except a lost answer after sending, which is "unknown".
// `HubChannelSigner.proof(context:)` is `package`: this file is the only caller (a source test enforces it).

/// What the person asks for: exactly the four decisions (L2B-3). There is no generic action, so no other type can be started from here.
public enum HubSignAction: Sendable, Equatable {
    case answerQuestion(log: String, question: String, hash: String, option: String?, text: String?)
    case approveGate(log: String, gate: String, hash: String)
    case requestChanges(log: String, gate: String, hash: String, text: String)
    case giveVerdict(log: String, outcome: String, hash: String, text: String?)

    var json: JSONValue {
        switch self {
        case let .answerQuestion(log, q, hash, option, text):
            var o: [String: JSONValue] = ["type": "question.answered", "log": .string(log), "question": .string(q), "hash": .string(hash)]
            if let option { o["option"] = .string(option) }
            if let text { o["text"] = .string(text) }
            return .object(o)
        case let .approveGate(log, gate, hash): return .object(["type": "gate.approved", "log": .string(log), "gate": .string(gate), "hash": .string(hash)])
        case let .requestChanges(log, gate, hash, text):
            return .object(["type": "gate.changes_requested", "log": .string(log), "gate": .string(gate), "hash": .string(hash), "text": .string(text)])
        case let .giveVerdict(log, outcome, hash, text):
            var o: [String: JSONValue] = ["type": "verdict.given", "log": .string(log), "outcome": .string(outcome), "hash": .string(hash)]
            if let text { o["text"] = .string(text) }
            return .object(o)
        }
    }
}

/// What the sign prompt shows. Built from `ctx` by `HubSignSession`; display only (`confirm` takes the prepared id, never this value).
public struct HubSignPrompt: Sendable, Equatable, Identifiable {
    public var id: String { preparedID }
    public let preparedID: String
    public let hubLabel: String
    public let facts: HubSign.Facts
    /// Short digest of what will be signed ("Signature reference").
    public let reference: String
    public let expiresMs: Int64
    /// Where the reviewed content can be read (content-bound decisions only; protocol 8.4).
    public let contentLink: URL?
}

public struct HubSignReceipt: Sendable, Equatable {
    public let eventID: String
    public let type: String
    public let workspaceID: String
    public let log: String
    public let hubLabel: String
    public let signedAtMs: Int64
}

/// Why nothing was signed (or, for `unknownOutcome`, why nobody can say). Fixed local meanings; nothing the hub wrote is shown.
public enum HubSignFailure: Error, Equatable, Sendable {
    /// The hub does not answer. Nothing was signed, nothing is queued.
    case offline
    case notPaired
    /// No valid channel session (expired, revoked, or the enrolled faces changed): sign in again with the password and a code.
    case signInAgain
    /// The request is not one of the four decisions the phone signs.
    case notSignable(type: String)
    /// A content-bound decision without a place to read the content: the phone offers only `question.answered` then.
    case contentNotReachable
    /// The prepared request is not what was asked for, or not what the phone computed, or not for this phone (`code` is the refusal).
    case changed(code: String)
    case expired
    case biometry(BiometryFailure)
    /// The hub refused (`code` is its error code; a fixed text per known code, else generic).
    case hub(code: String)
    /// The request was sent but the answer was lost. Nobody can tell if it was signed; do not retry: the item list shows the result.
    case unknownOutcome
    /// The phone could not read its own key or record.
    case custody
    /// A confirmation for this request is already running, or the request is not (any longer) held by this session.
    case notLive
}

public struct HubSignConfig: Sendable {
    public let custody: HubKeyCustody
    public let verifier: HubVerifier
    public let wall: any WallClock
    public let makeSender: @Sendable (String) throws -> any RequestSender
    public let biometry: BiometricGate
    /// Whether a workspace is one of this user's (the list of B2). Closed by default: a pushed request for a workspace nobody vouched for is
    /// refused.
    public let isMyWorkspace: @Sendable (String) async -> Bool
    /// A link for the person to look at the reviewed content (the hub's browser home is a stand-in; the independent check is Mission Control's
    /// content reference, L2-B3-3). Explicit on purpose: nil (the default) means content-bound decisions are not offered, questions still are.
    public let contentLink: @Sendable (_ origin: String, _ workspaceID: String, _ log: String) -> URL?
    /// The hub wipe (B6): while one is pending nothing is prepared, proved or sent, and a wipe drops every open request first.
    public let wipe: HubWipe?

    public init(custody: HubKeyCustody, verifier: HubVerifier = HubVerifier(), wall: any WallClock = SystemWallClock(),
                makeSender: @escaping @Sendable (String) throws -> any RequestSender = HubSenders.make,
                biometry: BiometricGate = BiometricGate(),
                isMyWorkspace: @escaping @Sendable (String) async -> Bool = { _ in false },
                contentLink: @escaping @Sendable (String, String, String) -> URL? = { _, _, _ in nil }, wipe: HubWipe? = nil) {
        self.wipe = wipe
        self.custody = custody; self.verifier = verifier; self.wall = wall; self.makeSender = makeSender; self.biometry = biometry
        self.isMyWorkspace = isMyWorkspace; self.contentLink = contentLink
    }
}

public actor HubSignSession {
    private let cfg: HubSignConfig
    private let hubID: String

    /// Held in memory only: a request is never kept across a launch (design B3). What is here was checked and rendered by this instance.
    private struct Live {
        let prompt: HubSignPrompt
        let ctx: JSONValue
        let digest: Data
        let started: HubSignAction?
        var confirming = false
    }
    private var live: [String: Live] = [:]

    public init(_ config: HubSignConfig, hubID: String) {
        cfg = config; self.hubID = hubID
        // phase 1 of every hub wipe: every open request is dropped, so an in-flight confirm finds it gone and makes no proof and no POST
        config.wipe?.onQuiesce { [weak self] _ in await self?.quiesce() }
    }

    private func quiesce() { live = [:] }

    /// The phone's own facts about this pairing, re-verified on every use (the card, the certificate, the key).
    struct Bindings {
        let record: HubPairingRecord
        let userID: String, channelID: String, keyPub: String, factor: String
    }

    // MARK: start: self-started

    /// `POST /sign/prepare` for `action` in `workspaceID`.
    public func prepare(workspaceID: String, action: HubSignAction) async throws -> HubSignPrompt {
        guard Hex.decode(workspaceID, length: 16) != nil else { throw HubSignFailure.changed(code: Refusal.malformed.rawValue) }
        let (b, api, bearer) = try context()
        let reply = try await call { try await api.prepare(bearer: bearer, workspaceID: workspaceID, channelID: b.channelID, action: action.json) }
        return try await accept(reply, bindings: b, started: action, requested: workspaceID)
    }

    // MARK: start: pushed (the seam B2 and B4 call)

    /// "Open the sign prompt for prepared id": `GET /sign/prepared/{id}`, then the same checks as a self-started request, except that there
    /// is no action to compare with, so the workspace must be one the caller vouches for (`isMyWorkspace`).
    public func open(preparedID: String) async throws -> HubSignPrompt {
        let (b, api, bearer) = try context()
        let reply = try await call { try await api.prepared(bearer: bearer, preparedID: preparedID) }
        guard reply.preparedID == preparedID else { throw HubSignFailure.changed(code: Refusal.eventChanged.rawValue) }
        return try await accept(reply, bindings: b, started: nil, requested: nil)
    }

    /// Drops a request the person dismissed. Nothing was signed.
    public func discard(preparedID: String) { live[preparedID] = nil }

    // MARK: confirm

    /// The person tapped Confirm. Checks the request is still live (and the hub answers), asks for Face ID (biometry only), makes the proof over
    /// the digest computed from the held `ctx`, and sends it. Takes the prepared id and nothing else: the signed bytes are the ones this
    /// instance rendered.
    public func confirm(preparedID: String) async throws -> HubSignReceipt {
        guard var held = live[preparedID], !held.confirming else { throw HubSignFailure.notLive }
        held.confirming = true; live[preparedID] = held
        var proofMade = false
        defer {
            // a request is single use once a proof was made; before that a cancelled or failed Face ID leaves it live for another try
            if proofMade { live[preparedID] = nil } else if var l = live[preparedID] { l.confirming = false; live[preparedID] = l }
        }
        try notExpired(held.prompt.expiresMs)
        let (b, api, bearer) = try context()
        // 1. the hub still answers and still holds exactly this request (a proof is made only while the hub is answering)
        let again = try await call { try await api.prepared(bearer: bearer, preparedID: preparedID) }
        if live[preparedID] == nil || Task.isCancelled { throw HubSignFailure.notLive }
        guard again.preparedID == preparedID, again.ctx == held.ctx, again.digestHex == Hex.encode(held.digest) else {
            live[preparedID] = nil
            throw HubSignFailure.changed(code: Refusal.eventChanged.rawValue)
        }
        // Cancel is structural (L2-B3-1): every step re-checks that this attempt is still live (not discarded) and not cancelled.
        func stillLive() throws { if live[preparedID] == nil || Task.isCancelled || (cfg.wipe?.pending ?? false) { throw HubSignFailure.notLive } }
        try stillLive()
        // 2. Face ID, biometry only; a changed set of faces drops the session
        do {
            let baseline = try? cfg.custody.biometryBaseline(hubID: hubID)
            try await cfg.biometry.authenticate(reason: "Sign for your hub", baseline: baseline)
        } catch let f as BiometryFailure {
            if f == .changed { try? cfg.custody.deleteSessionToken(hubID: hubID); live[preparedID] = nil; throw HubSignFailure.signInAgain }
            throw HubSignFailure.biometry(f)
        }
        try stillLive()                         // a Cancel during the Face ID sheet means no proof and no POST
        try notExpired(held.prompt.expiresMs)   // the prompt took time
        // 3. the proof, over the digest computed here from the held ctx
        let signer: HubChannelSigner
        let proof: HubProof
        do {
            signer = try cfg.custody.loadChannelKey(hubID: hubID)
            guard signer.channelID == b.channelID, signer.publicKey.x963 == (B64U.decode(b.keyPub) ?? Data()) else { throw HubSignFailure.custody }
            try stillLive()
            proof = try signer.proof(context: held.ctx)
            guard proof.digest == held.digest else { throw HubSignFailure.changed(code: Refusal.eventChanged.rawValue) }
        } catch let f as HubSignFailure { throw f } catch { throw HubSignFailure.custody }
        proofMade = true
        // 4. send; a lost answer is "unknown", never a retry
        do {
            let reply = try await api.sign(bearer: bearer, preparedID: preparedID, channelID: b.channelID, proof: proof.proof)
            guard reply.type.bytesEqual(held.prompt.facts.type), reply.log.bytesEqual(held.prompt.facts.log),
                  reply.workspaceID.bytesEqual(held.prompt.facts.workspaceID) else { throw HubSignFailure.unknownOutcome }
            return HubSignReceipt(eventID: reply.eventID, type: reply.type, workspaceID: reply.workspaceID, log: reply.log,
                                  hubLabel: held.prompt.hubLabel, signedAtMs: cfg.wall.nowMs)
        } catch HubAPIError.network { throw HubSignFailure.unknownOutcome }
        catch HubAPIError.badReply { throw HubSignFailure.unknownOutcome }
        catch let f as HubSignFailure { throw f }
        catch let e as HubAPIError { throw Self.map(e) }
        catch { throw HubSignFailure.unknownOutcome }
    }

    // MARK: checks

    private func accept(_ reply: HubPrepared, bindings b: Bindings, started: HubSignAction?, requested: String?) async throws -> HubSignPrompt {
        // 1. the allow-list: exactly the four decision types, before anything else is looked at or shown
        guard let type = reply.ctx.object?["event"]?.object?["type"]?.string else { throw HubSignFailure.changed(code: Refusal.malformed.rawValue) }
        guard HubSign.isDecisionType(type) else { throw HubSignFailure.notSignable(type: HubSign.renderText(String(type.prefix(64)))) }
        // 2. check_prepared: the shape, and the digest recomputed from ctx
        let digest: Data
        do { digest = try HubSign.checkPrepared(ctx: reply.ctx, digestHex: reply.digestHex) }
        catch let r as Refusal { throw HubSignFailure.changed(code: r.rawValue) }
        guard let ctx = reply.ctx.object, let event = ctx["event"], let log = ctx["log"]?.string, let ws = ctx["workspace_id"]?.string
        else { throw HubSignFailure.changed(code: Refusal.malformed.rawValue) }
        // 3. self-started: the event is the action that was sent
        if let started {
            do { try HubSign.checkBuilt(action: started.json, log: log, event: event) }
            catch let r as Refusal { throw HubSignFailure.changed(code: r.rawValue) }
            // beyond check_built (L2-B3-5): every action field the person chose is exactly what the hub built (a flipped outcome is refused)
            if let a = started.json.object, let e = event.object {
                for k in ["gate", "outcome", "question", "option", "text"] where !(a[k]?.string).bytesOptEqual(e[k]?.string) {
                    throw HubSignFailure.changed(code: Refusal.eventChanged.rawValue)
                }
            }
            if let requested, !requested.bytesEqual(ws) { throw HubSignFailure.changed(code: Refusal.eventChanged.rawValue) }
        }
        // 4. the phone's own bindings; a pushed request names a workspace nobody here asked for, so it must be one of this user's
        if started == nil, !(await cfg.isMyWorkspace(ws)) { throw HubSignFailure.changed(code: Refusal.eventChanged.rawValue) }
        try Self.checkBindings(event: event, workspaceID: ws, bindings: b, hubID: hubID)
        // 5. facts, from ctx and nothing else
        let facts: HubSign.Facts
        do { facts = try HubSign.facts(ctx: reply.ctx) } catch { throw HubSignFailure.changed(code: Refusal.malformed.rawValue) }
        try notExpired(reply.expiresMs)
        let link = cfg.contentLink(b.record.origin, ws, log)
        if HubSign.isContentBound(type), link == nil { throw HubSignFailure.contentNotReachable }
        let prompt = HubSignPrompt(preparedID: reply.preparedID, hubLabel: HubSign.renderText(b.record.label), facts: facts,
                                   reference: HubSign.shortDigest(digest), expiresMs: reply.expiresMs,
                                   contentLink: HubSign.isContentBound(type) ? link : nil)
        live[reply.preparedID] = Live(prompt: prompt, ctx: reply.ctx, digest: digest, started: started)
        return prompt
    }

    /// The event is for THIS phone, user and hub (protocol 8.4 step 3 plus design B3 step 2). Anything else is `event_changed`.
    static func checkBindings(event: JSONValue, workspaceID: String, bindings b: Bindings, hubID: String) throws {
        func fail() -> HubSignFailure { .changed(code: Refusal.eventChanged.rawValue) }
        guard let e = event.object, let eh = e["hub_id"]?.string, eh.bytesEqual(hubID),
              let ch = e["channel"]?.string, ch.bytesEqual(b.channelID),
              let actor = e["actor"]?.object, Set(actor.keys) == ["kind", "id", "via"], actor["kind"]?.string?.bytesEqual("person") == true,
              actor["id"]?.string?.bytesEqual("u_" + b.userID) == true, actor["via"]?.string?.bytesEqual(b.channelID) == true,
              let cert = e["channel_cert"]?.object?["o"]?.object, cert["channel_id"]?.string?.bytesEqual(b.channelID) == true,
              cert["key_pub"]?.string?.bytesEqual(b.keyPub) == true, cert["user_id"]?.string?.bytesEqual(b.userID) == true,
              cert["hub_id"]?.string?.bytesEqual(hubID) == true,
              let factor = e["channel_factor"]?.string, factor.bytesEqual(b.factor), cert["factor"]?.string?.bytesEqual(b.factor) == true,
              let uk = e["uk_cert"]?.object?["o"]?.object, uk["user_id"]?.string?.bytesEqual(b.userID) == true, uk["hub_id"]?.string?.bytesEqual(hubID) == true
        else { throw fail() }
    }

    // MARK: pairing, session, errors

    private func context() throws -> (Bindings, HubAPI, HubBearer) {
        if cfg.wipe?.pending ?? false { throw HubSignFailure.notPaired }
        let now = cfg.wall.nowMs
        let record: HubPairingRecord, cert: HubChannelCert
        do {
            guard let r = try HubPairingRecord.load(custody: cfg.custody, hubID: hubID, verifier: cfg.verifier, nowMs: now) else { throw HubSignFailure.notPaired }
            record = r
            let held = try cfg.verifier.verifyCard(r.card, nowMs: now)
            cert = try cfg.verifier.verifyChannelCert(r.channelCert, held: held, nowMs: now)
        } catch let f as HubSignFailure { throw f } catch let r as Refusal {
            // an expired or invalid certificate: this iPhone must pair again (B6 decides what to wipe)
            throw HubSignFailure.changed(code: r.rawValue)
        } catch { throw HubSignFailure.custody }
        let token: String?
        do { token = try cfg.custody.sessionToken(hubID: hubID) } catch { throw HubSignFailure.custody }
        guard let token, HubAPI.plausibleToken(token), record.sessionExpiresMs > now else { throw HubSignFailure.signInAgain }
        let api: HubAPI
        do { api = try record.api(makeSender: cfg.makeSender) } catch { throw HubSignFailure.offline }
        return (Bindings(record: record, userID: record.userID, channelID: record.channelID, keyPub: B64U.encode(cert.keyPub.x963), factor: cert.factor),
                api, HubBearer(token))
    }

    private func notExpired(_ expiresMs: Int64) throws {
        // never sign at or after expires_ms - 5 s
        guard cfg.wall.nowMs < expiresMs - 5_000 else { throw HubSignFailure.expired }
    }

    private func call<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() }
        catch HubAPIError.network { throw HubSignFailure.offline }
        catch let e as HubAPIError { throw Self.map(e) }
    }

    static func map(_ e: HubAPIError) -> HubSignFailure {
        switch e {
        case .network: return .offline
        case .badReply: return .changed(code: Refusal.malformed.rawValue)
        case .refused(let code, _):
            switch code {
            case "no_session": return .signInAgain
            case "event_changed": return .changed(code: code)
            case "prepared_expired", "unknown_prepared": return .expired
            default: return .hub(code: code)
            }
        }
    }
}

private extension Optional where Wrapped == String {
    func bytesOptEqual(_ o: String?) -> Bool {
        switch (self, o) { case (nil, nil): true; case let (a?, b?): a.bytesEqual(b); default: false }
    }
}
