import Foundation

/// What the phone last heard from a hub (design B2): the last workspace list and needs-you answer, per hub, shown read-only as "as of
/// <time>" while the hub is unreachable. It is never used to sign. It names the user and channel it belongs to, so a cache of another
/// pairing is not shown. It is dropped when the session ends, on a confirmed revoke, and by the hub wipe (B6).
public struct HubCacheEntry: Sendable, Equatable, Codable {
    public let hubID: String
    public let userID: String
    public let channelID: String
    public let asOfMs: Int64
    public let workspaces: [HubWorkspace]
    public let needsYou: HubNeedsYou
}

/// Where the cache lives. Failures are swallowed by the coordinator: a cache that cannot be written is simply not there.
public protocol HubCacheStore: Sendable {
    func read(hubID: String) -> Data?
    func write(_ data: Data, hubID: String) throws
    func remove(hubID: String)
}

public final class InMemoryHubCache: HubCacheStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    public init() {}
    public func read(hubID: String) -> Data? { lock.withLock { items[hubID] } }
    public func write(_ data: Data, hubID: String) throws { lock.withLock { items[hubID] = data } }
    public func remove(hubID: String) { lock.withLock { items[hubID] = nil } }
    public var hubIDs: [String] { lock.withLock { Array(items.keys) } }
}

/// One file per hub under `<directory>/<hub_id>.json`, written atomically with file protection "complete" (unreadable while the phone is
/// locked). `directory` is the hub's own area: it never shares a path with a direct-mode workspace container.
public struct FileHubCache: HubCacheStore {
    let directory: URL
    public init(directory: URL) { self.directory = directory }

    private func url(_ hubID: String) -> URL? {
        guard hubID.utf8.count == 32, hubID.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) else { return nil }
        return directory.appendingPathComponent(hubID + ".json")
    }

    public func read(hubID: String) -> Data? { url(hubID).flatMap { try? Data(contentsOf: $0) } }

    public func write(_ data: Data, hubID: String) throws {
        guard let u = url(hubID) else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: u, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: u, options: [.atomic])
        #endif
    }

    public func remove(hubID: String) { if let u = url(hubID) { try? FileManager.default.removeItem(at: u) } }

    /// Everything of every hub (the app's Reset; the hub wipe of B6 uses `remove`).
    public func removeAll() { try? FileManager.default.removeItem(at: directory) }
}
