import CryptoKit
import Foundation
import OrchProtocol

/// The replay window of a push hint (design B4): the size cap, the freshness rule and the per-channel table of ids already shown. Pure: no I/O,
/// no clock. `HubPushIntake` applies it under `ReplayStore`'s lock and persists the next state.
public enum PushReplay {
    public static let maxOuterBytes = 3072
    public static let maxAgeMs: Int64 = 24 * 3600 * 1000
    public static let skewMs: Int64 = 300_000
    /// Local limit: a hostile hub or relay could otherwise grow the persisted replay state without bound; the table stores SHA-256(id), never the id.
    public static let maxEntriesPerWorkspace = 512

    /// Why a hint was dropped.
    public enum DropReason: String, Sendable, Equatable {
        case size, shape, noKey = "no_key", tag, signature, payload, stale, replay
        /// Local limit, not a protocol reason: the channel's replay table is full (`maxEntriesPerWorkspace`). Refuse rather than evict.
        case capacity
    }

    /// Replay state of ONE channel (V3: the hub channel; the type keeps its old name): the highest `ts_ms` shown per id, and the highest `ts_ms` shown at all.
    /// Host-api v0 slice 4: the high-water mark is per workspace, so a high timestamp in workspace A can neither
    /// suppress nor prune anything of workspace B. (The realm is applied at the storage boundary, `ReplayStore`.)
    public struct WorkspaceReplay: Equatable, Sendable {
        /// Keyed by SHA-256 of the id's UTF-8 bytes: bounded size, and bytes never `String` (Swift equality is canonical
        /// equivalence, the protocol compares code points).
        public private(set) var lastShown: [Data: Int64]
        /// The highest `ts_ms` actually shown: host time under the WSK signature, not the local clock. The 24 h lower
        /// bound is `max(nowMs, maxShownTs) - 24 h` and entries older than `maxShownTs - 24 h` are pruned, so winding
        /// the clock back cannot make a pruned push replayable. A wrong local clock cannot move this mark, only a
        /// genuine signed push can (and only within `now + 300 s`). `Int64.min` means no history.
        public private(set) var maxShownTs: Int64
        /// Nothing at or below this is accepted. Seeded when history was lost on purpose or by accident (corrupt state:
        /// the time of recovery; a rejoin: the old generation's high-water mark), so a relay replaying a push that was
        /// already shown cannot show it again.
        public private(set) var notBeforeTs: Int64
        public init(lastShown: [Data: Int64] = [:], maxShownTs: Int64 = Int64.min, notBeforeTs: Int64 = Int64.min) {
            self.lastShown = lastShown; self.maxShownTs = maxShownTs; self.notBeforeTs = notBeforeTs
        }
        public static func key(_ id: String) -> Data { Data(SHA256.hash(data: Data(id.utf8))) }
        public func last(id: String) -> Int64? { lastShown[Self.key(id)] }
        public var isEmpty: Bool { lastShown.isEmpty && maxShownTs == Int64.min && notBeforeTs == Int64.min }
        public func with(notBeforeTs floor: Int64) -> WorkspaceReplay { WorkspaceReplay(lastShown: lastShown, maxShownTs: maxShownTs, notBeforeTs: max(notBeforeTs, floor)) }

        func pruned() -> WorkspaceReplay {
            let floor = saturatingAdd(maxShownTs, -PushReplay.maxAgeMs)
            return WorkspaceReplay(lastShown: lastShown.filter { $0.value >= floor }, maxShownTs: maxShownTs, notBeforeTs: notBeforeTs)
        }

        func recording(_ id: String, _ ts: Int64) -> WorkspaceReplay {
            var next = lastShown; next[Self.key(id)] = ts
            return WorkspaceReplay(lastShown: next, maxShownTs: max(maxShownTs, ts), notBeforeTs: notBeforeTs).pruned()
        }
    }

    /// The timestamp rule of section 9 steps 6 and 7 as a pure function: `max(nowMs, maxShownTs) - 24 h <= ts_ms <= nowMs + 300 s`
    /// (inclusive), and strictly higher than the last one shown for `(ws, id)`. `floorNowMs` is
    /// `maxShownTs` (see `ReplayState`); pass `Int64.min` when there is no history.
    public static func checkTimestamp(tsMs: Int64, nowMs: Int64, floorNowMs: Int64, lastShown: Int64?) -> DropReason? {
        guard tsMs >= saturatingAdd(max(nowMs, floorNowMs), -maxAgeMs), tsMs <= saturatingAdd(nowMs, skewMs) else { return .stale }
        if let last = lastShown, tsMs <= last { return .replay }
        return nil
    }
}
