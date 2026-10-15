import Foundation

/// Bounds the refetches that the relay's UNSIGNED `stale_epoch` hint can cause (protocol-v2 section 19.2, P3-D8; orch-29 Q3): at most
/// three refetch starts of the signed member list and grants per sliding 60 s, then 20, 40 and 60 s between starts (60 s from then
/// on). Only the relay's hint counts; a host-signed `stale_epoch` refusal fetches at once. The hint itself is never trusted: the epoch
/// moves only to what the signed list confirms.
///
/// Times are durations on the session's injected monotonic clock. The backoff starts afresh after `quiet` without a hint (every hint
/// counts, also one that is refused here), or when a refetch confirmed a newer epoch (`reset`): a relay cannot forge that. In memory.
package struct EpochRefetchLimiter: Equatable, Sendable {
    package static let window: Duration = .seconds(60)
    package static let perWindow = 3
    package static let backoff: [Duration] = [.seconds(20), .seconds(40), .seconds(60)]
    package static let quiet: Duration = .seconds(120)

    private var starts: [Duration] = []
    private var step = 0
    private var lastHint: Duration?

    package init() {}

    /// nil when a refetch may start at `now`, otherwise the earliest time it may.
    package func nextAllowed(at now: Duration) -> Duration? {
        if let h = lastHint, now - h >= Self.quiet { return nil }
        guard let last = starts.last else { return nil }
        let recent = starts.filter { now - $0 < Self.window }.count
        if step == 0 && recent < Self.perWindow { return nil }
        let earliest = last + Self.backoff[min(step, Self.backoff.count - 1)]
        return now >= earliest ? nil : earliest
    }

    /// A hint arrived at `now`: records a refetch start if one is allowed; false (no start recorded) otherwise.
    package mutating func admit(at now: Duration) -> Bool {
        if let h = lastHint, now - h >= Self.quiet { reset() }
        lastHint = now
        guard nextAllowed(at: now) == nil else { return false }
        let inBackoff = step > 0 || starts.filter { now - $0 < Self.window }.count >= Self.perWindow
        if inBackoff { step += 1 }
        starts = starts.filter { now - $0 < Self.window } + [now]
        return true
    }

    package mutating func reset() { starts = []; step = 0; lastHint = nil }
}
