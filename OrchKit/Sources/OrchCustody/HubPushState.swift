import Foundation
import OrchProtocol

/// The app's persisted push registration state for one hub (`.keys` group, app only): the newest `issued_ms` it signed (monotonic, so a
/// retry after a lost reply never reuses one), whether the hub holds the push key, and a digest of the last target it registered.
public struct HubPushState: Sendable, Equatable {
    public var issuedMs: Int64
    public var keyRegistered: Bool
    /// SHA-256 of `env || 0 || token`, hex: only the fact that the target changed, never the token itself.
    public var targetDigest: String?

    public init(issuedMs: Int64 = 0, keyRegistered: Bool = false, targetDigest: String? = nil) {
        self.issuedMs = issuedMs; self.keyRegistered = keyRegistered; self.targetDigest = targetDigest
    }

    func encoded() throws -> Data {
        try canonicalJSON(["v": 1, "issued_ms": .int(issuedMs), "key_registered": .bool(keyRegistered),
                           "target": targetDigest.map { JSONValue.string($0) } ?? .null])
    }

    static func decode(_ data: Data) throws -> HubPushState {
        guard let o = try StrictJSON.parse(data, maxBytes: 1024).object, Set(o.keys) == ["v", "issued_ms", "key_registered", "target"],
              o["v"] == .int(1), let i = o["issued_ms"]?.int, i >= 0, let k = o["key_registered"]?.bool else { throw Refusal.malformed }
        return HubPushState(issuedMs: i, keyRegistered: k, targetDigest: o["target"]?.string)
    }
}
