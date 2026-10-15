import Foundation
import OrchProtocol

/// Makes the ULIDs of host section 11A.14 14.1: the event id (also `opts.idem`) and a creation's ticket uid. 48-bit ms time from the
/// injected wall clock plus the adopted host offset (host = local + offset, the same rule as the bridge), 80 random bits from the injected
/// entropy (`SystemEntropy` in production). The host admits a never-seen id only within `[host now - 900 s, host now + 300 s]`.
public struct PhoneEventIDs: Sendable {
    private let wall: any WallClock
    private let entropy: any Entropy

    public init(wall: any WallClock, entropy: any Entropy = SystemEntropy()) { self.wall = wall; self.entropy = entropy }

    /// `offsetMs` is the adopted offset to host time; a missing offset is 0.
    public func next(offsetMs: Int64 = 0) throws -> String {
        try ULID.make(timeMs: saturatingAdd(wall.nowMs, offsetMs), random: entropy.bytes(ULID.randomLength))
    }
}
