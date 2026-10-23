import CryptoKit
import Foundation
import OrchCustody
import OrchProtocol
import OrchPush

// The phone's side of hub push (design B4): register the push key and the APNs target with the hub, and catch up from the channel's own relay
// mailbox. A push or mailbox message is a hint, never an authority; the relay's `channel_revoked` is unsigned and never wipes (L2B-2).

/// The APNs target the hub registers at the relay for this channel (`env`, `topic`, b64u device `token`).
public struct HubPushTarget: Sendable, Equatable {
    public let env: String, topic: String, token: String
    public init(env: PushEnvironment, topic: String = PushService.topic, token: String) {
        self.env = env.rawValue; self.topic = topic; self.token = token
    }
    var digest: String { Hex.encode(Data(SHA256.hash(data: Data((env + "\0" + topic + "\0" + token).utf8)))) }
}

public enum HubPushRegistration: Equatable, Sendable {
    /// The hub holds the key and this target.
    case registered
    /// Nothing to do: the hub already holds exactly this.
    case unchanged
    case notPaired
    /// No usable channel session (expired after 12 h, or none): sign in again, still paired.
    case noSession
    case channelRevoked
    case refused(String)
    case network
    case custody
}

public enum HubCatchUp: Equatable, Sendable {
    /// Handled messages (each opened, fresh and unseen, in id order) and how many were dropped (replay, stale, unopenable).
    case done(hints: [HubPushHint], dropped: Int)
    case notPaired
    /// The card names no relay: there is no mailbox.
    case noRelay
    case noMaterial
    /// Polling is stopped (the relay said revoked and the hub has not said otherwise).
    case paused
    /// The relay said `channel_revoked` and the hub answered: see `HubStatus`.
    case relayRevoked(HubStatus)
    case network
}

/// What the hub said when the phone asked after a relay `channel_revoked`.
public enum HubStatus: Equatable, Sendable {
    /// The hub also says revoked: B6 wipes (it never happens from the relay's word alone).
    case revoked
    /// The hub says the channel is live: the relay's claim is ignored for now, polling resumes after a pause.
    case live
    /// The hub could not be asked (offline, session expired): polling stays stopped until it can.
    case unconfirmed
}

/// Registers the push key and target, and catches up from the mailbox. One per install (D-B1).
public actor HubPushCoordinator {
    public struct Config: Sendable {
        let custody: HubKeyCustody
        let verifier: HubVerifier
        let wall: any WallClock
        let entropy: any Entropy
        let makeSender: @Sendable (String) throws -> any RequestSender
        /// Relay sender for the card's `relay_url`. Defaults to the same sender factory as the hub.
        let makeRelaySender: @Sendable (String) throws -> any RequestSender
        let intake: HubPushIntake
        /// Called when the relay claimed a revocation: drop whatever mailbox data is cached (nothing is wiped).
        let dropCache: @Sendable () -> Void

        public init(custody: HubKeyCustody, pushDir: URL, verifier: HubVerifier = HubVerifier(), wall: any WallClock = SystemWallClock(),
                    entropy: any Entropy = SystemEntropy(), makeSender: @escaping @Sendable (String) throws -> any RequestSender = HubSenders.make,
                    makeRelaySender: (@Sendable (String) throws -> any RequestSender)? = nil, dropCache: @escaping @Sendable () -> Void = {}) {
            self.custody = custody; self.verifier = verifier; self.wall = wall; self.entropy = entropy; self.makeSender = makeSender
            self.makeRelaySender = makeRelaySender ?? makeSender; self.intake = HubPushIntake(pushDir: pushDir); self.dropCache = dropCache
        }
    }

    /// After a relay `channel_revoked` that the hub did not confirm, the next try waits this long.
    static let pauseMs: Int64 = 15 * 60_000
    /// Messages handled per run (the relay holds at most 256).
    static let maxPerRun = 64

    private let cfg: Config
    private var stopped = false
    private var pausedUntilMs: Int64 = 0
    private var running = false

    public init(_ config: Config) { cfg = config }

    public var isPaused: Bool { stopped || cfg.wall.nowMs < pausedUntilMs }

    private struct Paired { let record: HubPairingRecord; let held: HeldHubCard; let signer: HubChannelSigner }

    private func paired() -> Paired? {
        guard let hubID = (try? cfg.custody.pairedHubs())?.first, let now = Optional(cfg.wall.nowMs),
              let record = try? HubPairingRecord.load(custody: cfg.custody, hubID: hubID, verifier: cfg.verifier, nowMs: now),
              let held = try? cfg.verifier.verifyCard(record.card, nowMs: now),
              let signer = try? cfg.custody.loadChannelKey(hubID: hubID), signer.channelID == record.channelID else { return nil }
        return Paired(record: record, held: held, signer: signer)
    }

    // MARK: push key and target

    /// Creates the push key if it does not exist and (re)writes `hub.push.material` (the extension's one item). Idempotent.
    private func ensureMaterial(_ p: Paired) throws {
        let hubID = p.record.hubID
        do { _ = try cfg.custody.loadPushKey(hubID: hubID) } catch CustodyError.missing { _ = try cfg.custody.createPushKey(hubID: hubID) }
        if let m = try? cfg.custody.pushMaterial(), m.hubID == hubID, m.channelID == p.record.channelID, m.label == p.record.label,
           m.opener.publicKey == (try cfg.custody.loadPushKey(hubID: hubID)).publicKey { return }
        try cfg.custody.publishPushMaterial(hubID: hubID, channelID: p.record.channelID, label: p.record.label)
    }

    /// After bind (and again whenever the APNs token changes, or at launch): publishes the extension's material, then
    /// `PUT /channels/{id}/push` with the channel-key-signed `hub.channel_push` (once; `null` afterwards) and the target.
    public func registerPush(_ target: HubPushTarget) async -> HubPushRegistration {
        guard let p = paired() else { return .notPaired }
        let hubID = p.record.hubID
        do { try ensureMaterial(p) } catch { return .custody }
        var state: HubPushState
        do { state = try cfg.custody.pushState(hubID: hubID) ?? HubPushState() } catch { return .custody }
        if state.keyRegistered, state.targetDigest == target.digest { return .unchanged }
        guard let token = try? cfg.custody.sessionToken(hubID: hubID) else { return .noSession }
        let api: HubAPI
        do { api = try p.record.api(makeSender: cfg.makeSender) } catch { return .network }
        guard let opener = try? cfg.custody.loadPushKey(hubID: hubID) else { return .custody }
        var sendKey = !state.keyRegistered
        for _ in 0..<3 {
            var signed: JSONValue?
            if sendKey {
                // Monotonic: always newer than anything signed before, persisted BEFORE the request so a lost reply never reuses one.
                let issued = max(cfg.wall.nowMs, state.issuedMs + 1)
                do {
                    signed = try p.signer.pushKey(hubID: hubID, pushPub: opener.publicKey, nowMs: issued)
                    state.issuedMs = issued
                    try cfg.custody.putPushState(state, hubID: hubID)
                } catch { return .custody }
            }
            do {
                try await api.registerPush(bearer: HubBearer(token), channelID: p.record.channelID, env: target.env, topic: target.topic,
                                           token: target.token, pushKey: signed)
                state.keyRegistered = true; state.targetDigest = target.digest
                do { try cfg.custody.putPushState(state, hubID: hubID) } catch { return .custody }
                return .registered
            } catch HubAPIError.refused(let code, _) {
                switch code {
                case "replay": sendKey = true; continue                       // the hub holds a newer key: sign a newer one
                case "malformed" where !sendKey: sendKey = true; continue     // the hub holds no key (lost): send it
                case "no_session", "forbidden_role", "unauthorized", "session_expired": return .noSession
                case "channel_revoked": return .channelRevoked
                default: return .refused(code)
                }
            } catch { return .network }
        }
        return .refused("replay")
    }

    // MARK: mailbox

    /// Channel-signed reads of the channel's relay mailbox (10.8.4): list, fetch each unseen id, open, hand the hint over, delete. Run when the
    /// app becomes active and after a push. Serialised: a second call while one runs returns an empty `.done`.
    public func catchUp() async -> HubCatchUp {
        guard !running else { return .done(hints: [], dropped: 0) }
        running = true; defer { running = false }
        if isPaused { return .paused }
        guard let p = paired() else { return .notPaired }
        guard let relayURL = p.held.relayURL else { return .noRelay }
        guard let material = try? cfg.custody.pushMaterial() else { return .noMaterial }
        let relay: HubChannelRelay
        do {
            relay = try HubChannelRelay(hubID: p.record.hubID, signer: p.signer, channelCert: p.record.channelCert,
                                        sender: try cfg.makeRelaySender(relayURL), wall: cfg.wall, entropy: cfg.entropy)
        } catch { return .network }
        var hints: [HubPushHint] = [], dropped = 0
        do {
            for entry in try await relay.list().prefix(Self.maxPerRun) {
                try Task.checkCancellation()
                guard let c = try await relay.get(entry.id) else { continue }
                switch cfg.intake.accept(material: material, hubID: p.record.hubID, channelID: p.record.channelID, messageID: entry.id,
                                         sealed: c, nowMs: cfg.wall.nowMs) {
                case .hint(let h): hints.append(h)
                case .dropped(.capacity): dropped += 1; continue   // the replay state could not be written: keep the message for the next run
                case .dropped: dropped += 1
                }
                // handled (shown, replayed, stale or unopenable): the phone deletes it so it is not read again
                try await relay.delete(entry.id)
            }
            return .done(hints: hints, dropped: dropped)
        } catch HubRelayError.channelRevoked {
            return .relayRevoked(await relayClaimedRevoked(p))
        } catch is CancellationError {
            return .done(hints: hints, dropped: dropped)
        } catch { return hints.isEmpty && dropped == 0 ? .network : .done(hints: hints, dropped: dropped) }
    }

    /// The relay's answer is unsigned: stop polling, drop the cache, ask the hub over the authenticated channel. Wipes nothing.
    private func relayClaimedRevoked(_ p: Paired) async -> HubStatus {
        stopped = true
        cfg.dropCache()
        let status = await askHub(p)
        switch status {
        case .live: stopped = false; pausedUntilMs = cfg.wall.nowMs + Self.pauseMs
        case .revoked, .unconfirmed: break
        }
        return status
    }

    /// Asks the hub whether this channel is still live (`GET /session` with the channel session): `channel_revoked` is the hub's own answer.
    public func askHub() async -> HubStatus {
        guard let p = paired() else { return .unconfirmed }
        let s = await askHub(p)
        if s == .live { stopped = false }
        return s
    }

    private func askHub(_ p: Paired) async -> HubStatus {
        guard let token = try? cfg.custody.sessionToken(hubID: p.record.hubID), let api = try? p.record.api(makeSender: cfg.makeSender) else { return .unconfirmed }
        do { try await api.confirmSession(HubBearer(token)); return .live }
        catch HubAPIError.refused("channel_revoked", _) { return .revoked }
        catch { return .unconfirmed }
    }
}
