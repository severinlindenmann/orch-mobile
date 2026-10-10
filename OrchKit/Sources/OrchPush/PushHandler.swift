import Foundation
import OrchProtocol
import OrchStore

/// The notification extension's whole decision, minus UserNotifications: material in, presentation out. Pure of
/// UI; its I/O is the keychain material source, the replay state file and the marker, all injected, so the real
/// pipeline runs under `swift test` and in the extension unchanged.
///
/// Order (A11/A12): peek the workspace from the outer shape, take that workspace's material and generation, then
/// inside `TombstoneCoordination.ifNotRemoved` (shared lock) and the workspace's replay lock: run `PushProcessor`
/// and persist the shown timestamp durably BEFORE anything is shown. A removed workspace writes nothing and shows
/// generic text. Rejected input is never routed.
public struct PushHandler: Sendable {
    public struct Result: Equatable, Sendable {
        public let presentation: PushPresentation
        public let outcome: NSEMarker.Outcome
    }

    let material: any PushMaterialSource
    let coordination: TombstoneCoordination
    let store: ReplayStore
    let realm: String
    let pushDir: URL
    let now: @Sendable () -> Date

    /// - Parameter pushDir: `<group.io.severin.orch>/push`, the same directory `StoreLayout.pushDir` names.
    public init(material: any PushMaterialSource, pushDir: URL, realm: String = Realm.live, now: @escaping @Sendable () -> Date = { Date() }) {
        self.material = material; self.pushDir = pushDir; self.realm = realm; self.now = now
        coordination = TombstoneCoordination(directories: [pushDir])
        store = ReplayStore(pushDir: pushDir, realm: realm)
    }

    public enum Realm { public static let live = "live" }

    /// Handles the `o` string of the remote notification. Records the marker (outcome only) before returning.
    public func handle(o: String?) -> Result {
        let r = decide(o: o)
        NSEMarker.record(r.outcome, pushDir: pushDir, nowMs: nowMs)
        return r
    }

    /// Timeout path: the marker records `expired`; the caller delivers `PushPresentation.generic`.
    public func recordExpired() { NSEMarker.record(.expired, pushDir: pushDir, nowMs: nowMs) }

    var nowMs: Int64 { Int64((now().timeIntervalSince1970 * 1000).rounded()) }

    func decide(o: String?) -> Result {
        func generic(_ why: NSEMarker.Outcome) -> Result { Result(presentation: .generic, outcome: why) }
        guard let o else { return generic(.droppedVerification) }
        let raw = Data(o.utf8)
        guard let ws = PushProcessor.workspace(ofOuter: raw) else { return generic(.droppedVerification) }
        let all: [ID16: PushMaterial]
        do { all = try material.loadAll(realm: realm) } catch { return generic(.droppedNoMaterial) }
        guard let mat = all[ws] else { return generic(.droppedNoMaterial) }
        let keys: PushProcessor.Keyring = [ws: mat.keys]
        let now = nowMs
        do {
            let ran = try coordination.ifNotRemoved(realm: realm, ws: ws.hex, generation: mat.generation) { () throws -> Result in
                try store.transact(workspace: ws, generation: mat.generation) { current in
                    let out = PushProcessor.process(outer: raw, keys: keys, replay: .init(workspaces: [ws: current]), nowMs: now)
                    switch out.result {
                    case .show(let p):
                        let pres = PushPresentation.make(p, workspaceName: mat.name)
                        let outcome = NSEMarker.Outcome(shown: p)
                        return (Result(presentation: pres, outcome: outcome), out.replay.replay(for: ws))
                    case .drop(let why):
                        let outcome = NSEMarker.Outcome(drop: why)
                        // A drop never changes persisted state (pruning is recomputed from the shown mark on each call).
                        return (generic(outcome), nil)
                    }
                }
            }
            return ran ?? generic(.droppedRemoved)
        } catch { return generic(.droppedState) }
    }
}
