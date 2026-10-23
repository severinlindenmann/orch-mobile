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
    /// The hub says this channel is revoked or its certificate expired: the cache is dropped; B6 wipes and offers to pair again.
    case revoked
    /// The sign-in again did not work; the phone is unchanged (still signed out, nothing kept).
    case signInFailed(HubSignInFailure)
}

public enum HubSignInFailure: Sendable, Equatable { case badCredentials, rateLimited, network, refused, verification }

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
    public private(set) var state: HubHomeState = .notPaired
    private var generation = 0
    private var refreshing: (id: Int, task: Task<HubHomeState, Never>)?
    private var refreshIDs = 0
    private var signingIn = false

    public init(custody: HubKeyCustody, cache: any HubCacheStore, verifier: HubVerifier = HubVerifier(), wall: any WallClock = SystemWallClock(),
                makeSender: @escaping @Sendable (String) throws -> any RequestSender = HubSenders.make) {
        self.custody = custody; self.cache = cache; self.verifier = verifier; self.wall = wall; self.makeSender = makeSender
    }

    // MARK: restore and refresh

    /// What can be shown without the network: the cached lists of the paired hub, read-only (never when the session is over). Call at
    /// launch, then `refresh()`.
    public func restore() -> HubHomeState {
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
            return set(classify(error, ctx), mine)
        }
    }

    /// The relay says this channel is revoked. Its answer is not signed (L2B-2), so it never wipes: stop trusting the cache at once, then
    /// ask the hub. If the hub answers, that answer decides (live, signed out, or revoked); if it cannot be reached, the phone stays
    /// read-only WITHOUT a cache.
    @discardableResult
    public func relayReportsRevoked() async -> HubHomeState {
        generation += 1                       // an in-flight refresh must not write the cache back
        if let hubID = try? custody.pairedHubs().first { cache.remove(hubID: hubID) }
        state = .offline(nil)
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
            // commit: token, then the record (the old session's expiry stays in force until the record is rewritten)
            try custody.putSessionToken(bound.bearer.token, hubID: hubID)
            try custody.putRecord(try canonicalJSON(next.json), hubID: hubID)
            generation += 1
        } catch {
            if let p = pairing { await api.signOut(p) }
            switch error {
            case HubAPIError.refused(let code, _) where code == "channel_revoked" || code == "cert_expired":
                cache.remove(hubID: hubID); state = .revoked
            case HubAPIError.refused(let code, _): state = .signInFailed(code == "bad_credentials" ? .badCredentials : code == "rate_limited" ? .rateLimited : .refused)
            case HubAPIError.network: state = .signInFailed(.network)
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
