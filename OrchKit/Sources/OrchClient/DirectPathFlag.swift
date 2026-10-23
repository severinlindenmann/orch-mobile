import Foundation
import OrchProtocol

/// B8 (orch-core #868): the direct-mode path (direct pairing, direct relay mailbox and push for one workspace) behind one flag.
///
/// Default ON for every workspace without a hub. It is turned OFF per workspace when the workspace reports `cut_over` (the relay answers
/// `403 cut_over` on a `/v2/workspaces/{ws}/...` route after the H5 switch, orch-core C10) and never turns itself back ON (reversal is a
/// human act on the Mac plus a fresh pairing). The phone then says "This workspace now uses your hub" and offers hub pairing; it never
/// drops the workspace silently. Removal of the whole path after rollout: the follow-up issue filed with this change.
public final class DirectPathFlag: @unchecked Sendable {
    public enum Decision: Equatable, Sendable {
        case allowed
        /// "This workspace now uses your hub": offer hub pairing (B1).
        case usesHub
    }

    private let store: any DirectPathStore
    private let lock = NSLock()
    private var observers: [@Sendable (String) -> Void] = []
    private var paired: (@Sendable (String) async -> Bool)?

    public init(store: any DirectPathStore = InMemoryDirectPathStore()) { self.store = store }

    /// Workspace ids (32 hex) whose direct path is closed.
    public var closedWorkspaces: Set<String> { store.closed() }

    public func isEnabled(workspace ws: String) -> Bool { !store.closed().contains(ws.lowercased()) }

    public func decision(workspace ws: String) -> Decision { isEnabled(workspace: ws) ? .allowed : .usesHub }

    /// Which workspace ids this phone is paired with. A cut-over for any other id is ignored: the relay's `403 cut_over` is
    /// unauthenticated, so a hostile relay must not be able to grow the OFF set. nil (never set): every cut-over is ignored (fail closed).
    public func setPairedCheck(_ f: (@Sendable (String) async -> Bool)?) { lock.lock(); paired = f; lock.unlock() }

    static let maxClosed = 256

    /// The workspace reported `relay.cut_over` (or `cut_over`): switch OFF for it, if this phone is paired with it. Idempotent.
    /// ACCEPTED RISK (documented in PR): a forged `403 cut_over` from a hostile relay can switch a paired workspace's direct path OFF
    /// (a DoS of the direct path only); `reenable` ("Use direct connection again") undoes it, and a real cut-over is re-detected.
    public func noteCutOver(workspace ws: String) async {
        let id = ws.lowercased()
        guard ID16(hex: id) != nil else { return }
        guard let check = pairedCheck(), await check(id) else { return }
        insert(id)
    }

    private func pairedCheck() -> (@Sendable (String) async -> Bool)? { lock.lock(); defer { lock.unlock() }; return paired }

    private func insert(_ id: String) {
        lock.lock()
        var s = store.closed()
        let isNew = s.count < Self.maxClosed && s.insert(id).inserted
        if isNew { store.setClosed(s) }
        let o = observers
        lock.unlock()
        if isNew { o.forEach { $0(id) } }
    }

    /// Manual "Use direct connection again" (workspace settings): turns the direct path back ON for this workspace. The next
    /// `cut_over` switches it off again.
    public func reenable(workspace ws: String) {
        lock.lock(); defer { lock.unlock() }
        var s = store.closed()
        if s.remove(ws.lowercased()) != nil { store.setClosed(s) }
    }

    /// Called once per workspace that just switched OFF, so the UI can show "This workspace now uses your hub".
    public func onSwitchedOff(_ f: @escaping @Sendable (String) -> Void) { lock.lock(); observers.append(f); lock.unlock() }

    /// Gate for a NEW direct pairing. The card or QR may state the hub mode; `full` is refused (the hub is the only path), and so is any
    /// workspace this phone already knows to be cut over. `selective` and "no hub" stay allowed (D80: the direct path stays open).
    public func admitPairing(workspace ws: String, cardHubMode: HubWorkspace.Mode?) -> Decision {
        if cardHubMode == .full { return .usesHub }
        return decision(workspace: ws)
    }

    /// Reads the relay's refusal body: `403` with error `cut_over` / `relay.cut_over`.
    static func isCutOver(status: Int, body: Data) -> Bool {
        guard status == 403, let o = (try? StrictJSON.parse(body, maxBytes: 1 << 16))?.object, let e = o["error"]?.string else { return false }
        return e == "cut_over" || e == "relay.cut_over"
    }

    /// `/v2/workspaces/<32 hex>/...` -> the workspace id.
    static func workspace(inTarget target: String, base: String) -> String? {
        let prefix = base + "/workspaces/"
        guard target.hasPrefix(prefix) else { return nil }
        let rest = target.dropFirst(prefix.count)
        let id = rest.prefix(32)
        return id.count == 32 && ID16(hex: String(id)) != nil ? String(id) : nil
    }
}

/// Where the OFF set lives. Not a secret: workspace ids only.
public protocol DirectPathStore: Sendable {
    func closed() -> Set<String>
    func setClosed(_ s: Set<String>)
}

public final class InMemoryDirectPathStore: DirectPathStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Set<String> = []
    public init() {}
    public func closed() -> Set<String> { lock.lock(); defer { lock.unlock() }; return value }
    public func setClosed(_ s: Set<String>) { lock.lock(); value = s; lock.unlock() }
}

public struct UserDefaultsDirectPathStore: DirectPathStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private static let key = "orch.directPath.closed"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func closed() -> Set<String> { Set(defaults.stringArray(forKey: Self.key) ?? []) }
    public func setClosed(_ s: Set<String>) { defaults.set(Array(s).sorted(), forKey: Self.key) }
}
