import Foundation
import OrchCustody
import OrchProtocol

// The phone's view of its hub (design B2). ONE `HubHomeCoordinator` per process owns the hub's list, the cache and every refresh; the
// views only render its state. Requests go through the channel session bound to the origin verified at pairing (D2, `HubPairingRecord.api`),
// never to an origin from anywhere else.

public struct HubSnapshot: Sendable, Equatable {
    public let workspaces: [HubWorkspace]
    public let needsYou: HubNeedsYou
    /// When the hub answered (the phone's own clock at that moment).
    public let asOfMs: Int64

    public func rows(in workspaceID: String) -> [HubNeedsYouRow] { needsYou.rows.filter { $0.workspaceID == workspaceID } }
}

public enum HubHomeState: Sendable, Equatable {
    /// No hub pairing on this iPhone.
    case notPaired
    /// The hub answered just now.
    case live(HubSnapshot)
    /// The hub could not be reached or sent something unusable. The snapshot is the cached one (read-only, "Hub offline"), or nil when there
    /// is none. Nothing can be signed from here.
    case offline(HubSnapshot?)
    /// The 12 h session is over (or the hub no longer knows it): still paired, sign in again. The cache is dropped.
    case signedOut
    /// The hub itself said this channel is revoked or its certificate expired (an authenticated answer), or the certificate ran out by the
    /// phone's own clock. The cache is dropped; for the hub's answer the pairing is wiped (B6), and "Pair again" starts a new one. After a
    /// local expiry nothing is wiped until the person chooses "Pair again" (`pairAgain`): a wrong clock must not wipe a good phone.
    case revoked
    /// The sign-in again did not work; the phone is unchanged (still signed out, nothing kept).
    case signInFailed(HubSignInFailure)
}

public enum HubSignInFailure: Sendable, Equatable { case badCredentials, rateLimited, network, refused, verification }

/// How a Leave ended (B6).
public enum HubLeaveOutcome: Sendable, Equatable {
    /// There was no pairing to leave.
    case notPaired
    /// The pairing is wiped. `revokedAtHub` says whether the hub confirmed the revoke; when it did not, the person is told to ask the hub
    /// admin to remove this iPhone (the key is gone either way).
    case left(revokedAtHub: Bool)
    /// The wipe did not finish; it resumes at the next launch.
    case incomplete
}

public enum HubItemResult: Sendable, Equatable {
    case detail(HubItemDetail)
    /// The hub could not be reached: no item is shown from the cache.
    case offline
    case refused(code: String)
    /// The session ended or the channel was revoked (the home state changed too).
    case ended(HubHomeState)
}

public actor HubHomeCoordinator {
    private let custody: HubKeyCustody
    private let verifier: HubVerifier
    private let wall: any WallClock
    private let makeSender: @Sendable (String) throws -> any RequestSender
    private let cache: any HubCacheStore
    private let wipe: HubWipe
    public private(set) var state: HubHomeState = .notPaired
    private var generation = 0
    private var refreshing: (id: Int, task: Task<HubHomeState, Never>)?
    private var refreshIDs = 0
    private var signingIn = false

    public init(custody: HubKeyCustody, cache: any HubCacheStore, verifier: HubVerifier = HubVerifier(), wall: any WallClock = SystemWallClock(),
                makeSender: @escaping @Sendable (String) throws -> any RequestSender = HubSenders.make, wipe: HubWipe? = nil) {
        self.custody = custody; self.cache = cache; self.verifier = verifier; self.wall = wall; self.makeSender = makeSender
        self.wipe = wipe ?? HubWipe(custody: custody, cache: cache)
    }

    // MARK: restore and refresh

    /// What can be shown without the network: the cached lists of the paired hub, read-only (never when the session is over). Call at
    /// launch, then `refresh()`.
    public func restore() async -> HubHomeState {
        if let s = await finishPendingWipe() { state = s; return s }
        switch context() {
        case .end(let s): state = s
        case .ok(let ctx): state = .offline(cached(ctx))
        }
        return state
    }

    /// Asks the hub. One refresh at a time per process: a caller during a refresh gets that refresh's answer.
    @discardableResult
    public func refresh() async -> HubHomeState {
        if let r = refreshing { return await r.task.value }
        refreshIDs += 1
        let id = refreshIDs
        let t = Task { await self.runRefresh() }
        refreshing = (id, t)
        let s = await t.value
        if refreshing?.id == id { refreshing = nil }
        return s
    }

    private func runRefresh() async -> HubHomeState {
        if let s = await finishPendingWipe() { return s }
        generation += 1
        let mine = generation
        let ctx: Context
        switch context() {
        case .ok(let c): ctx = c
        case .end(let s): return set(s, mine)
        }
        do {
            let ws = try await ctx.api.myWorkspaces(ctx.bearer)
            let ny = try await ctx.api.needsYou(ctx.bearer, workspaces: ws)
            guard mine == generation else { return state }
            let snap = HubSnapshot(workspaces: ws, needsYou: ny, asOfMs: wall.nowMs)
            store(snap, ctx)
            return set(.live(snap), mine)
        } catch {
            guard mine == generation else { return state }
            let s = classify(error, ctx)
            if s == .revoked { await wipeAfterHubRevoke(ctx.record); state = .revoked; return .revoked }
            return set(s, mine)
        }
    }

    /// A wipe an earlier run did not finish is finished before anything else (nothing of a half-wiped hub is used). Nil: nothing pending, or
    /// it finished. `.revoked`: it could not finish (the pairing is not usable; "Pair again" retries).
    private func finishPendingWipe() async -> HubHomeState? {
        guard wipe.pending else { return nil }
        generation += 1
        refreshing?.task.cancel()
        do { try await wipe.resume() } catch { return .revoked }
        return nil
    }

    /// The hub's own authenticated answer (`channel_revoked` or `cert_expired` to a channel-session request or to a bind) wipes the pairing,
    /// the cache included (R3: a revoked phone may be a stolen phone). Only the pairing the answer was about: if the stored channel is no longer
    /// `record`'s (the person paired again meanwhile), a late answer wipes nothing. A relay's answer never gets here (L2B-2).
    private func wipeAfterHubRevoke(_ record: HubPairingRecord) async {
        guard let stored = try? custody.record(hubID: record.hubID), let now = try? HubPairingRecord.decode(stored),
              now.channelID == record.channelID else { return }
        generation += 1
        refreshing?.task.cancel()
        cache.remove(hubID: record.hubID)
        try? await wipe.wipe(.hub(record.hubID))      // a failure leaves the journal: the next launch (or `pairAgain`) finishes it
    }

    // MARK: leave and pair again (B6)

    /// Leave the hub: ask the hub to revoke this phone's channel (its own channel session, its own channel), then wipe whatever the answer. A
    /// failed revoke is reported (`revokedAtHub: false`); the keys are gone either way. The cache goes first so nothing is shown while it runs.
    public func leave() async -> HubLeaveOutcome {
        if wipe.pending { _ = await finishPendingWipe() }
        guard let hubID = (try? custody.pairedHubs())?.first else { state = .notPaired; return .notPaired }
        generation += 1                          // an in-flight refresh must not write the cache back, nor sign anything on
        refreshing?.task.cancel(); refreshing = nil
        cache.remove(hubID: hubID)
        var revoked = false
        if let data = try? custody.record(hubID: hubID), let rec = try? HubPairingRecord.decode(data), rec.hubID == hubID,
           let token = (try? custody.sessionToken(hubID: hubID)) ?? nil, let api = try? rec.api(makeSender: makeSender) {
            do { try await api.revokeChannel(HubBearer(token), channelID: rec.channelID); revoked = true }
            catch HubAPIError.refused(let code, _) where code == "channel_revoked" { revoked = true }     // already revoked: nothing to ask
            catch {}
        }
        do { try await wipe.wipe(.hub(hubID)) } catch { state = .revoked; return .incomplete }
        state = .notPaired
        return .left(revokedAtHub: revoked)
    }

    /// "Pair again" after `.revoked`: removes what is left of the old pairing (after a local certificate expiry nothing was wiped yet), so a
    /// new pairing starts clean. The person chose this, so it needs no hub answer. Returns `.notPaired` when pairing may start.
    public func pairAgain() async -> HubHomeState {
        generation += 1
        refreshing?.task.cancel(); refreshing = nil
        if let hubID = (try? custody.pairedHubs())?.first { try? await wipe.wipe(.hub(hubID)) } else { try? await wipe.resume() }
        state = ((try? custody.pairedHubs())?.isEmpty ?? false) && !wipe.pending ? .notPaired : .revoked
        return state
    }

    /// The relay says this channel is revoked. Its answer is not signed (L2B-2), so it never wipes: stop trusting the cache at once, then
    /// ask the hub. If the hub answers, that answer decides (live, signed out, or revoked); if it cannot be reached, the phone stays
    /// read-only WITHOUT a cache.
    @discardableResult
    public func relayReportsRevoked() async -> HubHomeState {
        generation += 1                       // an in-flight refresh must not write the cache back
        if let hubID = try? custody.pairedHubs().first { cache.remove(hubID: hubID) }
        state = .offline(nil)           // (B6) the pairing stays; only an answer from the hub itself can wipe it
        refreshing?.task.cancel()
        refreshing = nil
        return await refresh()
    }

    // MARK: sign in again (the 12 h session is over; still paired)

    /// Password + TOTP through the existing sign-in (a 15-minute pairing session), then `hub.channel_auth` signed by THIS phone's channel key
    /// binds it to the channel again. Same scopes as pairing; the origin is the one stored at pairing. Nothing is stored before every check
    /// passed (the new answer is verified like at pairing), so a failure keeps the old state. Does not need a live session or a cache.
    @discardableResult
    public func signInAgain(password: String, totp: String) async -> HubHomeState {
        guard !signingIn else { return state }
        signingIn = true
        defer { signingIn = false }
        guard let hubID = (try? custody.pairedHubs())?.first else { state = .notPaired; return state }
        let record: HubPairingRecord, held: HeldHubCard
        do {
            guard let r = try HubPairingRecord.load(custody: custody, hubID: hubID, verifier: verifier, nowMs: wall.nowMs) else { state = .notPaired; return state }
            record = r; held = try verifier.verifyCard(r.card, nowMs: wall.nowMs)
        } catch Refusal.certExpired {
            cache.remove(hubID: hubID); state = .revoked; return state
        } catch { cache.remove(hubID: hubID); state = .offline(nil); return state }
        var pairing: HubBearer?
        let api: HubAPI
        do { api = try record.api(makeSender: makeSender) } catch { state = .signInFailed(.network); return state }
        do {
            let signedIn = try await api.signIn(userID: record.userID, password: password, totp: totp)
            pairing = signedIn.bearer
            guard signedIn.userID == record.userID else { throw Refusal.otherUser }
            let signer = try custody.loadChannelKey(hubID: hubID)
            guard signer.channelID == record.channelID else { throw Refusal.certInvalid }
            let auth = try signer.channelAuth(hubID: hubID, userID: record.userID, sessionToken: signedIn.bearer.token, nowMs: wall.nowMs)
            let bound = try await api.bindChannel(bearer: signedIn.bearer, auth: auth)
            let now = wall.nowMs
            guard bound.userID == record.userID, bound.channelID == record.channelID else { throw Refusal.otherUser }
            let card2 = try verifier.verifyCard(bound.card, nowMs: now, pinnedRoot: held.hkRootPub, held: held)
            let cert2 = try verifier.verifyChannelCert(bound.channelCert, held: card2, nowMs: now)
            try HubPairingCoordinator.checkOwnCert(cert2, hubID: hubID, userID: record.userID, signer: signer)
            guard bound.expiresMs > now, bound.expiresMs <= saturatingAdd(saturatingAdd(now, HubPairingCoordinator.channelSessionMs), HubVerifier.clockSkewMs)
            else { throw Refusal.malformed }
            let next = HubPairingRecord(hubID: hubID, origin: record.origin, userID: record.userID, channelID: record.channelID, label: record.label,
                                        card: bound.card, channelCert: bound.channelCert, sessionExpiresMs: bound.expiresMs, pairedMs: record.pairedMs)
            // the last await is behind us: the key must still be this channel's and the record the one we loaded (a wipe or Leave during
            // the bind must not be undone by a record for a deleted key; L2-B2-5, the pairing step-5 check)
            guard (try? custody.loadChannelKey(hubID: hubID))?.channelID == record.channelID,
                  let stored = try? custody.record(hubID: hubID), (try? HubPairingRecord.decode(stored)) == record
            else { throw CustodyError.missing }
            // commit: token, then the record (the old session's expiry stays in force until the record is rewritten)
            try custody.putSessionToken(bound.bearer.token, hubID: hubID)
            try custody.putRecord(try canonicalJSON(next.json), hubID: hubID)
            generation += 1
        } catch {
            if let p = pairing { await api.signOut(p) }
            switch error {
            case HubAPIError.refused(let code, _) where code == "channel_revoked" || code == "cert_expired":
                cache.remove(hubID: hubID); await wipeAfterHubRevoke(record); state = .revoked
            case HubAPIError.refused(let code, _): state = .signInFailed(code == "bad_credentials" ? .badCredentials : code == "rate_limited" ? .rateLimited : .refused)
            case HubAPIError.network: state = .signInFailed(.network)
            case is CustodyError: state = .signInFailed(.verification)
            default: state = .signInFailed(.verification)
            }
            return state
        }
        return await refresh()
    }

    // MARK: item

    /// One item through the hub. Only while the hub answers: an item is never shown from the cache.
    public func item(workspaceID: String, itemID: String) async -> HubItemResult {
        guard HubViewParse.isWorkspaceID(workspaceID), HubViewParse.isItemID(itemID) else { return .refused(code: "malformed") }
        guard case .ok(let ctx) = context() else { return .ended(state) }
        guard case .live(let snap) = state, snap.workspaces.contains(where: { $0.id == workspaceID }) else {
            if case .offline = state { return .offline }
            return .refused(code: "unknown_workspace")
        }
        do {
            return .detail(try await ctx.api.item(ctx.bearer, workspaceID: workspaceID, itemID: itemID, workspaces: snap.workspaces))
        } catch HubAPIError.refused(let code, _) where !["no_session", "channel_revoked", "cert_expired"].contains(code) {
            return .refused(code: code)
        } catch {
            let s = classify(error, ctx)
            if s == .revoked { await wipeAfterHubRevoke(ctx.record) }
            generation += 1
            state = s
            if case .offline = s { return .offline }
            return .ended(s)
        }
    }

    // MARK: pieces

    private struct Context { let record: HubPairingRecord; let api: HubAPI; let bearer: HubBearer }
    private enum Ctx { case ok(Context), end(HubHomeState) }

    /// The verified pairing, its API (always the stored origin), and the session token. A session past its expiry, a missing token or a record
    /// that does not verify ends the view (cache dropped); nothing is guessed.
    private func context() -> Ctx {
        guard let hubID = (try? custody.pairedHubs())?.first else { return .end(.notPaired) }
        let record: HubPairingRecord
        do {
            guard let r = try HubPairingRecord.load(custody: custody, hubID: hubID, verifier: verifier, nowMs: wall.nowMs) else { return .end(.notPaired) }
            record = r
        } catch Refusal.certExpired {
            cache.remove(hubID: hubID); return .end(.revoked)
        } catch {
            cache.remove(hubID: hubID); return .end(.offline(nil))      // fails closed: nothing unverified is shown
        }
        guard wall.nowMs < record.sessionExpiresMs, let token = (try? custody.sessionToken(hubID: hubID)) ?? nil else {
            cache.remove(hubID: hubID); return .end(.signedOut)
        }
        guard let api = try? record.api(makeSender: makeSender) else { cache.remove(hubID: hubID); return .end(.offline(nil)) }
        return .ok(Context(record: record, api: api, bearer: HubBearer(token)))
    }

    private func classify(_ error: Error, _ ctx: Context) -> HubHomeState {
        let hubID = ctx.record.hubID
        switch error {
        case HubAPIError.refused(let code, _) where code == "no_session":
            cache.remove(hubID: hubID); return .signedOut
        case HubAPIError.refused(let code, _) where code == "channel_revoked" || code == "cert_expired":
            cache.remove(hubID: hubID); return .revoked
        default:
            // unreachable, refused for another reason, or an answer that does not have the contract's shape: read-only, from the cache
            return .offline(cached(ctx))
        }
    }

    private func set(_ s: HubHomeState, _ mine: Int) -> HubHomeState {
        guard mine == generation else { return state }
        state = s; return s
    }

    private func cached(_ ctx: Context) -> HubSnapshot? { cached(ctx.record) }

    private func cached(_ r: HubPairingRecord) -> HubSnapshot? {
        guard let data = cache.read(hubID: r.hubID), let e = try? JSONDecoder().decode(HubCacheEntry.self, from: data),
              e.hubID == r.hubID, e.userID == r.userID, e.channelID == r.channelID, e.asOfMs <= wall.nowMs + HubVerifier.clockSkewMs else {
            cache.remove(hubID: r.hubID); return nil
        }
        return HubSnapshot(workspaces: e.workspaces, needsYou: e.needsYou, asOfMs: e.asOfMs)
    }

    private func store(_ s: HubSnapshot, _ ctx: Context) {
        let e = HubCacheEntry(hubID: ctx.record.hubID, userID: ctx.record.userID, channelID: ctx.record.channelID, asOfMs: s.asOfMs,
                              workspaces: s.workspaces, needsYou: s.needsYou)
        if let d = try? JSONEncoder().encode(e) { try? cache.write(d, hubID: ctx.record.hubID) }
    }
}
