import Foundation
import OrchProtocol

/// The notification extension's whole decision, minus UserNotifications: hub push material in, presentation out (design B4). Pure of UI; its I/O
/// is the keychain material source, the replay state files and the marker, all injected, so the real pipeline runs under `swift test` and in the
/// extension unchanged.
///
/// A hint is never an authority: the extension opens it with the PUSH key only, shows the person's own hub label with one of two fixed lines, and
/// records the replay state durably BEFORE anything is shown. Rejected input, missing material or an unreadable state is the generic text.
public struct PushHandler: Sendable {
    public struct Result: Equatable, Sendable {
        public let presentation: PushPresentation
        public let outcome: NSEMarker.Outcome
        init(presentation: PushPresentation, outcome: NSEMarker.Outcome) { self.presentation = presentation; self.outcome = outcome }
    }

    let hubMaterial: any HubPushMaterialSource
    let pushDir: URL
    let now: @Sendable () -> Date

    /// - Parameter pushDir: `<group.io.severin.orch>/push`.
    public init(hubMaterial: any HubPushMaterialSource, pushDir: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.hubMaterial = hubMaterial; self.pushDir = pushDir; self.now = now
    }

    /// The keychain service realm of the hub push material item.
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

    var nowMs: Int64 { Int64((now().timeIntervalSince1970 * 1000).rounded()) }

    func decide(o: String?) -> Result {
        func generic(_ why: NSEMarker.Outcome) -> Result { Result(presentation: .generic, outcome: why) }
        guard let o else { return generic(.droppedVerification) }
        let raw = Data(o.utf8)
        guard HubPushOuter.isHub(raw), let outer = HubPushOuter.parse(raw) else { return generic(.droppedVerification) }
        let mat: HubPushMaterial
        do { guard let m = try hubMaterial.load() else { return generic(.droppedNoMaterial) }; mat = m } catch { return generic(.droppedNoMaterial) }
        let verdict = HubPushIntake(pushDir: pushDir).accept(material: mat, hubID: outer.hubID, channelID: outer.channelID,
                                                             messageID: outer.messageID, sealed: outer.sealed, nowMs: nowMs,
                                                             work: .unguarded)    // the extension has no session; see HubWorkBarrier
        switch verdict {
        case .hint(let hint): return Result(presentation: .hubHint(hint.type, label: mat.label), outcome: .shown)
        case .dropped(let why): return generic(NSEMarker.Outcome(drop: why))
        }
    }
}
