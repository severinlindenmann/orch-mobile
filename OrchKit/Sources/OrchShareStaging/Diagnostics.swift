import Foundation
import OrchCoordination

/// On-device support evidence for the share index ("Share targets status" in the app's Demo controls and the share
/// extension's "Details"). Only fixed labels, booleans, counts, sizes, dates, protection classes and error codes:
/// never a path, a workspace name or file content.
public enum ShareDiagnostics {
    public struct Line: Sendable, Hashable, Identifiable {
        public let label: String
        public let value: String
        public var id: String { label }
        public init(_ label: String, _ value: String) { self.label = label; self.value = value }
    }

    /// `root` is what `containerURL(forSecurityApplicationGroupIdentifier:)` returned (nil: not resolvable).
    /// `lockTimeout` bounds the tombstone lock probe so the UI never hangs on a held lock.
    public static func collect(groupID: String, root: URL?, lockTimeout: TimeInterval = 1,
                               attributes: (String) -> [FileAttributeKey: Any]? = { try? FileManager.default.attributesOfItem(atPath: $0) }) -> [Line] {
        var out: [Line] = [Line("App Group", groupID)]
        guard let root else {
            out.append(Line("Container", "not resolvable (entitlement or provisioning profile)"))
            return out
        }
        out.append(Line("Container", "resolvable"))
        out.append(Line("Container path form", root.path.hasPrefix("/private/") ? "/private/… (device)" : "other"))
        let area = ShareArea(shareGroupRoot: root)
        let dirAttrs = attributes(area.shareDir.path)
        out.append(Line("Share folder", dirAttrs == nil ? "missing" : "present, protection \(protection(dirAttrs))"))
        out.append(Line("Path check", area.components(of: area.targetsURL) == ["targets.json"] ? "ok" : "refused"))

        if let a = attributes(area.targetsURL.path) {
            let size = (a[.size] as? NSNumber)?.intValue ?? -1
            let date = (a[.modificationDate] as? Date).map(stamp) ?? "?"
            out.append(Line("Index file", "\(size) bytes, modified \(date), protection \(protection(a))"))
        } else {
            out.append(Line("Index file", "missing"))
        }

        if let s = ShareTargetIndex.PublishStatus.read(from: area) {
            out.append(Line("Last app publish", "\(stamp(Date(timeIntervalSince1970: s.at))): \(s.result), \(s.targets) targets"))
        } else {
            out.append(Line("Last app publish", "no record"))
        }

        do {
            let file = try ShareTargetIndex.readFile(from: area)
            let demo = file.targets.filter { $0.realm == "demo" }.count
            out.append(Line("Index decode", "ok, version \(file.version), \(file.targets.count) targets (\(demo) Demo)"))
        } catch {
            out.append(Line("Index decode", code(error)))
        }

        // Probe only an existing folder: the probe creates the lock file, never the share folder itself.
        out.append(Line("Tombstone lock", dirAttrs == nil ? "skipped (no share folder)" : lockProbe(area, timeout: lockTimeout)))
        do {
            let live = try ShareTargetIndex.load(from: area)
            out.append(Line("Offered", "\(live.count) destinations"))
        } catch {
            out.append(Line("Offered", code(error)))
        }
        // The share path never touches the keychain: the extension has no keychain-access-groups entitlement and may not
        // link Security (scripts/check-extension-links.sh). Stated so nobody chases a keychain cause.
        out.append(Line("Keychain", "not used by the share index"))
        return out
    }

    /// Fixed code for any error on the index path.
    public static func code(_ error: Error) -> String {
        switch error as? ShareError {
        case .noWorkspaces: "none"
        case .index(let f): f.code
        case .some(let e): "\(e)"
        case nil: "other"
        }
    }

    /// Takes the shared tombstone lock exactly as the extension does (creating the lock file if missing).
    static func lockProbe(_ area: ShareArea, timeout: TimeInterval) -> String {
        do {
            let r = try area.coordination.ifNotRemoved(realm: "diagnostics", ws: String(repeating: "0", count: 32), generation: 0, timeout: timeout) { true }
            guard r == true else { return "acquired, tombstones unreadable" }
            let count = (try? area.coordination.records().count).map { "\($0) records" } ?? "records unreadable"
            return "acquired (shared), \(count)"
        } catch {
            return "failed: \(ShareTargetIndex.tombstoneCode(error))"
        }
    }

    static func protection(_ attrs: [FileAttributeKey: Any]?) -> String {
        guard let raw = attrs?[.protectionKey] else { return "n/a" }
        let s = (raw as? FileProtectionType)?.rawValue ?? (raw as? String) ?? "?"
        return s.replacingOccurrences(of: "NSFileProtection", with: "")
    }

    static func stamp(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
}
