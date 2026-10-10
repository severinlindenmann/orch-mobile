import Foundation

public enum ShareItemKind: String, Codable, Sendable { case file, text, url }

public struct StagedItem: Codable, Equatable, Sendable {
    /// Display name only. The stored file is always `file` (`item-<n>`), never a provider-chosen path.
    public let name: String
    public let kind: ShareItemKind
    public let type: String?
    public let bytes: Int
    public let file: String
}

public struct JobManifest: Codable, Equatable, Sendable {
    public var version = 1
    public var jobID: String
    public var realm: String
    public var ws: String
    public var generation: Int64
    /// Seconds since 1970.
    public var createdAt: Double
    public var note: String?
    public var items: [StagedItem]
    public var totalBytes: Int { items.reduce(0) { $0 + $1.bytes } }

    /// Every field a reader uses to build a path or a destination is validated here, so a hostile writer of the
    /// share group cannot steer the app with a crafted manifest.
    func isValid() -> Bool {
        guard version == 1, JobID.isValid(jobID),
              (try? ShareArea.validate(realm: realm, ws: ws)) != nil,
              (1...ShareLimits.maxItems).contains(items.count),
              (note?.count ?? 0) <= ShareLimits.maxNoteCharacters, createdAt.isFinite else { return false }
        var total = 0
        for (i, item) in items.enumerated() {
            guard item.file == "item-\(i + 1)", item.bytes >= 0, item.bytes <= ShareLimits.maxTotalBytes,
                  item.name.unicodeScalars.count <= ShareLimits.maxNameCharacters,
                  (item.type?.utf8.count ?? 0) <= 255 else { return false }
            total += item.bytes
        }
        return total <= ShareLimits.maxTotalBytes
    }
}

enum JobFiles {
    static let manifest = "manifest.json"
    static let ready = "READY"
    static let claimedSuffix = ".claimed"
}

/// What an input looks like to the stager. File inputs are copied while the provider's URL is valid.
public enum ShareInput: Sendable {
    /// The temporary copy the item provider framework made for us (`loadFileRepresentation`). The only input that
    /// may live under the extension's own home; still refused inside any App Group container.
    case providerCopy(URL, name: String, type: String?)
    /// A file URL value. Strict: refused under the share group, any App Group container, or the extension's home.
    case file(URL, name: String, type: String?)
    case text(String)
    /// A URL is text: it is stored and shown, never fetched.
    case url(String)
}
