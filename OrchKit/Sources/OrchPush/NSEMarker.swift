import Foundation
import OrchCoordination

/// The notification extension's invocation marker (decision A12, challenge C2): written by the extension itself on every
/// invocation, so a test can tell "the extension ran" from "a notification appeared". It holds a counter, an outcome
/// enum and a timestamp, and nothing decrypted: no label, no id, no workspace name, not even the workspace id.
public struct NSEMarker: Equatable, Codable, Sendable {
    public enum Outcome: String, Codable, Sendable, CaseIterable {
        case shown, closed, droppedVerification, droppedReplay, droppedNoMaterial, droppedRemoved, droppedState, joinHidden, expired

        /// `stale` counts as replay: both are "not fresh".
        public init(drop why: PushProcessor.DropReason) {
            switch why {
            case .replay, .stale: self = .droppedReplay
            case .noKey: self = .droppedNoMaterial
            case .capacity: self = .droppedState
            default: self = .droppedVerification
            }
        }
        public init(shown p: PushProcessor.Payload) { self = p.kind == "question.closed" ? .closed : p.kind == "join" ? .joinHidden : .shown }
    }
    public let count: Int
    public let outcome: Outcome
    public let atMs: Int64

    public static let fileName = "nse-marker.json"
    public static let lockName = "nse-marker.lock"

    /// Increments the counter under flock and replaces the file atomically. Best effort: a failure never blocks delivery.
    /// `bestEffort: true` (the expiry path) takes the lock with LOCK_NB and skips the fsyncs: it never waits.
    @discardableResult
    public static func record(_ outcome: Outcome, pushDir: URL, nowMs: Int64, bestEffort: Bool = false) -> NSEMarker? {
        do {
            try CoordinationFiles.makeDir(pushDir)
            return try CoordinationFiles.withFlock(pushDir.appendingPathComponent(lockName).path, blocking: !bestEffort) { () throws -> NSEMarker in
                let next = NSEMarker(count: (read(pushDir: pushDir)?.count ?? 0) + 1, outcome: outcome, atMs: nowMs)
                try CoordinationFiles.atomicWrite(try JSONEncoder().encode(next), to: pushDir.appendingPathComponent(fileName), dir: pushDir, durable: !bestEffort)
                return next
            }
        } catch { return nil }
    }

    public static func read(pushDir: URL) -> NSEMarker? {
        (try? Data(contentsOf: pushDir.appendingPathComponent(fileName))).flatMap { try? JSONDecoder().decode(NSEMarker.self, from: $0) }
    }
}
