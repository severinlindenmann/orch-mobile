import Foundation
import OrchCoordination
import OrchCustody
import OrchProtocol

/// The notification extension's whole decision, minus UserNotifications: material in, presentation out. Pure of
/// UI; its I/O is the keychain material source, the replay state file and the marker, all injected, so the real
/// pipeline runs under `swift test` and in the extension unchanged.
///
/// Order (A11/A12): peek the workspace from the outer shape, take that workspace's material and generation, then
/// inside `TombstoneCoordination.ifNotRemoved` (shared lock) and the workspace's replay lock: run `PushProcessor`
/// and persist the shown timestamp durably BEFORE anything is shown. A removed workspace writes nothing and shows
/// generic text. Rejected input is never routed.
public struct PushHandler: Sendable {
    /// What must still hold at the moment of delivery: the workspace is not removed and nothing newer for the same id has
    /// been accepted. Carried from processing to `finalize` (A11: "check the generation ... before handing off content").
    public struct Handoff: Equatable, Sendable {
        public let workspace: ID16
        public let generation: Int64
        public let id: String
        public let tsMs: Int64
    }

    public struct Result: Equatable, Sendable {
        public let presentation: PushPresentation
        public let outcome: NSEMarker.Outcome
        public let handoff: Handoff?
        init(presentation: PushPresentation, outcome: NSEMarker.Outcome, handoff: Handoff? = nil) {
            self.presentation = presentation; self.outcome = outcome; self.handoff = handoff
        }
    }

    let material: any PushMaterialSource
    let hubMaterial: (any HubPushMaterialSource)?
    let coordination: TombstoneCoordination
    let store: ReplayStore
    let realm: String
    let pushDir: URL
    let now: @Sendable () -> Date

    /// - Parameter pushDir: `<group.io.severin.orch>/push`, the same directory `StoreLayout.pushDir` names.
    public init(material: any PushMaterialSource, hubMaterial: (any HubPushMaterialSource)? = nil, pushDir: URL, realm: String = Realm.live,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.material = material; self.hubMaterial = hubMaterial; self.pushDir = pushDir; self.realm = realm; self.now = now
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

    /// Timeout path: the marker records `expired`, best effort (never waits for a lock, no fsync); the caller delivers
    /// `PushPresentation.generic` first.
    public func recordExpired() { NSEMarker.record(.expired, pushDir: pushDir, nowMs: nowMs, bestEffort: true) }

    /// Hands the content over INSIDE the protected check: holding the shared removal lock and the workspace's replay lock,
    /// it re-checks that the workspace is still present at the material's generation and that no NEWER push for the
    /// same id has been accepted (a question must not appear after its closure committed), and calls `deliver` with
    /// the result while still holding both. A wipe or a closure can therefore only commit before the check or after
    /// the handler was called, never between. `deliver` must be quick and must not take these locks.
    ///
    /// Waiting for the locks is bounded by `timeout`; on timeout, removal, supersession or any error `deliver` gets
    /// `PushPresentation.generic`. `deliver` is called at most once from here (the caller's claim makes it idempotent
    /// against the deadline path).
    public func handoff(_ r: Result, timeout: TimeInterval = 3, deliver: (PushPresentation) -> Void) {
        guard let h = r.handoff else { deliver(r.presentation); return }
        var delivered = false
        func once(_ p: PushPresentation) { if !delivered { delivered = true; deliver(p) } }
        do {
            let ran: Void? = try coordination.ifNotRemoved(realm: realm, ws: h.workspace.hex, generation: h.generation, timeout: timeout) { () throws -> Void in
                try store.transact(workspace: h.workspace, generation: h.generation, nowMs: nowMs, lockTimeout: timeout) { cur in
                    once(cur.last(id: h.id) == h.tsMs ? r.presentation : .generic)
                    return ((), nil)
                }
            }
            if ran == nil { once(.generic) }
        } catch { once(.generic) }
    }

    /// Convenience for tests and callers that only need the decision: the presentation `handoff` would deliver.
    public func finalize(_ r: Result) -> PushPresentation {
        var out = PushPresentation.generic
        handoff(r) { out = $0 }
        return out
    }

    var nowMs: Int64 { Int64((now().timeIntervalSince1970 * 1000).rounded()) }

    func decide(o: String?) -> Result {
        func generic(_ why: NSEMarker.Outcome) -> Result { Result(presentation: .generic, outcome: why) }
        guard let o else { return generic(.droppedVerification) }
        let raw = Data(o.utf8)
        if HubPushOuter.isHub(raw) { return decideHub(raw) }
        guard let ws = PushProcessor.workspace(ofOuter: raw) else { return generic(.droppedVerification) }
        let all: [ID16: PushMaterial]
        do { all = try material.loadAll(realm: realm) } catch { return generic(.droppedNoMaterial) }
        guard let mat = all[ws] else { return generic(.droppedNoMaterial) }
        let keys: PushProcessor.Keyring = [ws: mat.keys]
        let now = nowMs
        do {
            let ran = try coordination.ifNotRemoved(realm: realm, ws: ws.hex, generation: mat.generation) { () throws -> Result in
                try store.transact(workspace: ws, generation: mat.generation, nowMs: now) { current in
                    let out = PushProcessor.process(outer: raw, keys: keys, replay: .init(workspaces: [ws: current]), nowMs: now)
                    switch out.result {
                    case .show(let p):
                        let pres = PushPresentation.make(p, workspaceName: mat.name)
                        let outcome = NSEMarker.Outcome(shown: p)
                        return (Result(presentation: pres, outcome: outcome, handoff: pres.style == .generic ? nil : Handoff(workspace: ws, generation: mat.generation, id: p.id, tsMs: p.tsMs)), out.replay.replay(for: ws))
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

    /// A hub push (design B4): the push key only, the person's own hub label as the title, fixed body text. Replay is recorded durably before
    /// anything is returned. Any failure is the generic text and a marker outcome; nothing here signs or reaches the network.
    func decideHub(_ raw: Data) -> Result {
        func generic(_ why: NSEMarker.Outcome) -> Result { Result(presentation: .generic, outcome: why) }
        guard let outer = HubPushOuter.parse(raw) else { return generic(.droppedVerification) }
        guard let source = hubMaterial else { return generic(.droppedNoMaterial) }
        let mat: HubPushMaterial
        do { guard let m = try source.load() else { return generic(.droppedNoMaterial) }; mat = m } catch { return generic(.droppedNoMaterial) }
        let verdict = HubPushIntake(pushDir: pushDir).accept(material: mat, hubID: outer.hubID, channelID: outer.channelID,
                                                             messageID: outer.messageID, sealed: outer.sealed, nowMs: nowMs)
        switch verdict {
        case .hint(let hint): return Result(presentation: .hubHint(hint.type, label: mat.label), outcome: .shown)
        case .dropped(let why): return generic(NSEMarker.Outcome(drop: why))
        }
    }
}
