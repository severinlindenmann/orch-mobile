import Foundation
import OrchCustody
import OrchProtocol

// Pairing this phone with a hub (design B1, orch-hub protocol 6.3 and 6.4). Staged: nothing is committed before every check passed, and a
// failure at any step leaves no key, token or row.

public struct HubPairingPreview: Sendable, Equatable {
    public let hubID: String
    /// The hub id in 8 groups of 4: what the person compares with the admin console next to the QR.
    public let fingerprint: String
    /// The API host (and port) the signed `hub.api_origin` named, as a person reads it.
    public let host: String
    public let origin: String
}

public struct HubPairingSummary: Sendable, Equatable {
    public let hubID: String
    public let fingerprint: String
    public let host: String
    public let userID: String
    public let channelID: String
    public let label: String
    public let sessionExpiresMs: Int64
}

public enum HubPairingStep: Sendable, Equatable { case signingIn, creatingKey, registering, binding }

/// Why a pairing stopped. Fixed local meanings; nothing the hub wrote is shown.
public enum HubPairingFailure: Error, Equatable, Sendable {
    case badLink
    case alreadyPaired
    /// The card names another hub than the link: the pin never changes silently.
    case otherHub
    /// The hub's signed API origin is not the link's: nothing was sent (possible phishing link).
    case otherOrigin
    /// A card or origin object was refused (`code` is the contract refusal, e.g. `dev_refused` in a release build).
    case cardRefused(String)
    case badCredentials
    case rateLimited
    case pairingCodeRejected
    case noSession
    case hubRefused(String)
    /// A hub answer failed verification (`code` is the contract refusal).
    case verification(String)
    case network
    case custody
}

public enum HubPairingState: Sendable, Equatable {
    case idle
    case checking
    /// The card and the signed origin verified; waiting for password and TOTP.
    case confirm(HubPairingPreview)
    case working(HubPairingStep)
    case paired(HubPairingSummary)
    case failed(HubPairingFailure)
}

/// What the phone keeps of a pairing (the commit point: written last). The card, the origin and the certificate are re-verified on load.
public struct HubPairingRecord: Sendable, Equatable {
    public let hubID: String
    /// The API origin verified at pairing. Every later request goes here, never to an origin from a later link, push or answer.
    public let origin: String
    public let userID: String
    public let channelID: String
    public let label: String
    public let card: JSONValue
    public let channelCert: JSONValue
    public let sessionExpiresMs: Int64
    public let pairedMs: Int64

    var json: JSONValue {
        .object(["v": 1, "hub_id": .string(hubID), "origin": .string(origin), "user_id": .string(userID), "channel_id": .string(channelID),
                 "label": .string(label), "card": card, "channel_cert": channelCert, "session_expires_ms": .int(sessionExpiresMs),
                 "paired_ms": .int(pairedMs)])
    }

    static func decode(_ data: Data) throws -> HubPairingRecord {
        guard let o = try StrictJSON.parse(data, maxBytes: 64 << 10).object,
              Set(o.keys) == ["v", "hub_id", "origin", "user_id", "channel_id", "label", "card", "channel_cert", "session_expires_ms", "paired_ms"],
              o["v"] == .int(1), let h = o["hub_id"]?.string, let origin = o["origin"]?.string, let u = o["user_id"]?.string,
              let c = o["channel_id"]?.string, let l = o["label"]?.string, let card = o["card"], let cert = o["channel_cert"],
              let exp = o["session_expires_ms"]?.int, let paired = o["paired_ms"]?.int else { throw Refusal.malformed }
        return HubPairingRecord(hubID: h, origin: origin, userID: u, channelID: c, label: l, card: card, channelCert: cert,
                                sessionExpiresMs: exp, pairedMs: paired)
    }

    /// The stored record of `hubID`, re-verified: the card (pinned to the stored hub id), the signed origin is the stored one by
    /// construction, and the channel certificate under that card for this user and channel. Fails closed (throws) on anything unreadable.
    public static func load(custody: HubKeyCustody, hubID: String, verifier: HubVerifier = HubVerifier(), nowMs: Int64) throws -> HubPairingRecord? {
        guard let data = try custody.record(hubID: hubID) else { return nil }
        let r = try decode(data)
        guard r.hubID == hubID else { throw Refusal.otherHub }
        let held = try verifier.verifyCard(r.card, nowMs: nowMs)
        guard held.hubID == hubID else { throw Refusal.otherHub }
        let cert = try verifier.verifyChannelCert(r.channelCert, held: held, nowMs: nowMs)
        guard cert.userID == r.userID, cert.channelID == r.channelID else { throw Refusal.otherUser }
        return r
    }

    /// The API client for this pairing: always the stored origin.
    public func api(makeSender: (String) throws -> any RequestSender) throws -> HubAPI {
        try HubAPI(origin: origin, sender: try makeSender(origin))
    }
}

public struct HubPairingConfig: Sendable {
    public let custody: HubKeyCustody
    public let verifier: HubVerifier
    public let wall: any WallClock
    /// A sender bound to exactly the origin it is given (production: `HubSenders.make`).
    public let makeSender: @Sendable (String) throws -> any RequestSender

    public init(custody: HubKeyCustody, verifier: HubVerifier = HubVerifier(), wall: any WallClock = SystemWallClock(),
                makeSender: @escaping @Sendable (String) throws -> any RequestSender = HubSenders.make) {
        self.custody = custody; self.verifier = verifier; self.wall = wall; self.makeSender = makeSender
    }
}

/// The production sender for a hub origin: https via Network.framework (system trust, TLS 1.2+, no redirects, response cap), or, in a
/// DEBUG build only, plain http to a loopback address with a port (the dev hub in the Simulator).
public enum HubSenders {
    @Sendable public static func make(origin: String) throws -> any RequestSender {
        if origin.hasPrefix("https://") { return try NWRequestSender(origin: origin) }
        #if DEBUG
        return try NWRequestSender(loopbackOrigin: origin)
        #else
        throw RealmViolation.invalidOrigin
        #endif
    }
}

/// One pairing at a time. `begin` reaches the hub and verifies; `complete` signs in and pairs; `cancel` forgets everything staged.
public actor HubPairingCoordinator {
    private let cfg: HubPairingConfig
    public private(set) var state: HubPairingState = .idle
    private var pending: Pending?
    private var busy = false
    private var generation = 0

    private struct Pending {
        let link: HubPairLink
        let held: HeldHubCard
        let origin: String
        let api: HubAPI
        let preview: HubPairingPreview
    }

    public init(_ config: HubPairingConfig) { cfg = config }

    /// Parse the link, fetch the card, verify it pinned to the link's hub_id, verify the HK_op-signed API origin equals the link's.
    /// No password is sent before all of that passed.
    public func begin(link text: String) async -> HubPairingState {
        guard !busy else { return state }
        busy = true; generation += 1; pending = nil
        let mine = generation
        defer { if mine == generation { busy = false } }
        state = .checking
        let link: HubPairLink
        do { link = try cfg.verifier.parseLink(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        catch { return finish(mine, .failed(.badLink)) }
        do {
            guard try cfg.custody.pairedHubs().isEmpty else { return finish(mine, .failed(.alreadyPaired)) }
            let api = try HubAPI(origin: link.api, sender: try cfg.makeSender(link.api))
            let answer = try await api.hubCard()
            guard mine == generation else { return state }
            let now = cfg.wall.nowMs
            let held = try cfg.verifier.verifyCard(answer.card, nowMs: now)
            guard held.hubID == link.hubID else { throw Refusal.otherHub }
            _ = try cfg.verifier.verifyAPIOrigin(answer.apiOrigin, held: held, linkAPI: link.api, nowMs: now)
            let preview = HubPairingPreview(hubID: held.hubID, fingerprint: HubIdentifiers.fingerprint(hubID: held.hubID) ?? held.hubID,
                                            host: Self.host(of: link.api), origin: link.api)
            pending = Pending(link: link, held: held, origin: link.api, api: api, preview: preview)
            return finish(mine, .confirm(preview))
        } catch {
            return finish(mine, .failed(Self.failure(error, whileChecking: true)))
        }
    }

    /// Sign in (password + TOTP), create the channel key, register and verify the certificate, bind. Commits only at the very end.
    public func complete(password: String, totp: String, label: String) async -> HubPairingState {
        guard !busy, let p = pending, case .confirm = state else { return state }
        busy = true
        let mine = generation
        defer { if mine == generation { busy = false } }
        let hubID = p.held.hubID
        var pairingSession: HubBearer?
        var keyCreated = false
        func rollback() async {
            if keyCreated || (try? cfg.custody.record(hubID: hubID)) == nil { try? cfg.custody.deleteAll(hubID: hubID) }
            if let s = pairingSession { await p.api.signOut(s) }
            pending = nil
        }
        do {
            let hubLabel = try Self.cleanLabel(label)
            // 1. sign in: a 15-minute pairing session, held in memory only
            state = .working(.signingIn)
            let signedIn = try await p.api.signIn(userID: p.link.userID, password: password, totp: totp)
            pairingSession = signedIn.bearer
            guard mine == generation else { await rollback(); return state }
            guard signedIn.userID == p.link.userID else { throw Refusal.otherUser }
            // 2. the channel key (a leftover key of an interrupted pairing has no record and is replaced)
            state = .working(.creatingKey)
            try? cfg.custody.deleteAll(hubID: hubID)
            let signer: HubChannelSigner
            do { signer = try cfg.custody.createChannelKey(hubID: hubID); keyCreated = true } catch { throw HubPairingFailure.custody }
            // 3. register: the hub's challenge is checked field by field BEFORE the key signs it
            state = .working(.registering)
            let begun = try await p.api.registerBegin(bearer: signedIn.bearer, keyPub: signer.publicKey, pairingCode: p.link.code)
            guard mine == generation else { await rollback(); return state }
            let challenge = try cfg.verifier.checkRegistrationChallenge(begun.challenge, challengeID: begun.challengeID, hubID: hubID,
                                                                        userID: p.link.userID, ownKey: signer.publicKey, nowMs: cfg.wall.nowMs)
            let certJSON = try await p.api.registerComplete(bearer: signedIn.bearer, challengeID: begun.challengeID,
                                                            signed: try signer.register(challenge))
            let cert = try cfg.verifier.verifyChannelCert(certJSON, held: p.held, nowMs: cfg.wall.nowMs)
            try Self.checkOwnCert(cert, hubID: hubID, userID: p.link.userID, signer: signer)
            // 4. bind the pairing session to the channel; the answer is verified before anything is kept
            state = .working(.binding)
            let auth = try signer.channelAuth(hubID: hubID, userID: p.link.userID, sessionToken: signedIn.bearer.token, nowMs: cfg.wall.nowMs)
            let bound = try await p.api.bindChannel(bearer: signedIn.bearer, auth: auth)
            guard mine == generation else { await rollback(); return state }
            let now = cfg.wall.nowMs
            guard bound.userID == p.link.userID, bound.channelID == signer.channelID else { throw Refusal.otherUser }
            let card2 = try cfg.verifier.verifyCard(bound.card, nowMs: now, pinnedRoot: p.held.hkRootPub, held: p.held)
            let cert2 = try cfg.verifier.verifyChannelCert(bound.channelCert, held: card2, nowMs: now)
            try Self.checkOwnCert(cert2, hubID: hubID, userID: p.link.userID, signer: signer)
            guard bound.expiresMs > now, bound.expiresMs <= saturatingAdd(saturatingAdd(now, Self.channelSessionMs), HubVerifier.clockSkewMs)
            else { throw Refusal.malformed }
            // 5. commit: the token first, the record LAST (the record is what makes the phone paired)
            let record = HubPairingRecord(hubID: hubID, origin: p.origin, userID: p.link.userID, channelID: signer.channelID, label: hubLabel,
                                          card: bound.card, channelCert: bound.channelCert, sessionExpiresMs: bound.expiresMs, pairedMs: now)
            do {
                try cfg.custody.putSessionToken(bound.bearer.token, hubID: hubID)
                try cfg.custody.putRecord(try canonicalJSON(record.json), hubID: hubID)
            } catch { throw HubPairingFailure.custody }
            pending = nil
            let summary = HubPairingSummary(hubID: hubID, fingerprint: p.preview.fingerprint, host: p.preview.host, userID: record.userID,
                                            channelID: record.channelID, label: hubLabel, sessionExpiresMs: record.sessionExpiresMs)
            return finish(mine, .paired(summary))
        } catch {
            await rollback()
            return finish(mine, .failed(Self.failure(error, whileChecking: false)))
        }
    }

    /// Forgets the staged pairing (nothing was committed before `complete` finished).
    public func cancel() {
        generation += 1; pending = nil; busy = false; state = .idle
    }

    private func finish(_ mine: Int, _ s: HubPairingState) -> HubPairingState {
        guard mine == generation else { return state }
        state = s; return s
    }

    static let channelSessionMs: Int64 = 12 * 3_600_000

    /// The certificate must be OUR key's, for the signed-in user, on this hub, and `se-unlocked` (anything else: nothing is kept).
    static func checkOwnCert(_ c: HubChannelCert, hubID: String, userID: String, signer: HubChannelSigner) throws {
        guard c.hubID == hubID, c.userID == userID else { throw Refusal.otherUser }
        guard c.keyPub == signer.publicKey, c.channelID == signer.channelID else { throw Refusal.certInvalid }
        guard c.factor == "se-unlocked" else { throw Refusal.factorMismatch }
    }

    /// The name the person gives the hub (it is the title of its notifications): 1 to 40 printable characters.
    static func cleanLabel(_ s: String) throws -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(t.unicodeScalars.count), PersonText.clean(t) == t, !t.contains("\n") else { throw HubPairingFailure.verification("label") }
        return t
    }

    static func host(of origin: String) -> String {
        guard let c = URLComponents(string: origin), let h = c.host else { return origin }
        return c.port.map { "\(h):\($0)" } ?? h
    }

    static func failure(_ error: Error, whileChecking: Bool) -> HubPairingFailure {
        switch error {
        case let f as HubPairingFailure: return f
        case let r as Refusal:
            switch r {
            case .otherHub: return .otherHub
            case .otherOrigin: return .otherOrigin
            default: return whileChecking ? .cardRefused(r.rawValue) : .verification(r.rawValue)
            }
        case HubAPIError.network: return .network
        case HubAPIError.refused(let code, _):
            switch code {
            case "bad_credentials": return .badCredentials
            case "rate_limited": return .rateLimited
            case "bad_pairing_code": return .pairingCodeRejected
            case "no_session": return .noSession
            default: return .hubRefused(code)
            }
        case is HubAPIError: return .verification("bad_reply")
        case is CustodyError: return .custody
        default: return .network
        }
    }
}
