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
    public static func collect(groupID: String, root: URL?, lockTimeout: TimeInterval = 1) -> [Line] {
        var out: [Line] = [Line("App Group", groupID)]
        guard let root else {
            out.append(Line("Container", "not resolvable (entitlement or provisioning profile)"))
            return out
        }
        out.append(Line("Container", "resolvable"))
        out.append(Line("Container path form", root.path.hasPrefix("/private/") ? "/private/… (device)" : "other"))
        let area = ShareArea(shareGroupRoot: root)
        // fd-relative only (module rule): a `share` or `targets.json` swapped for a link is refused, never followed.
        var folderPresent = false
        var folderRefused = false
        do {
            let dir = try area.openDir(area.shareDir)
            folderPresent = true
            out.append(Line("Share folder", "present, protection \(protection(fd: dir.fd))"))
        } catch {
            let code = fsCode(error, missing: "missing")
            folderRefused = code != "missing"
            out.append(Line("Share folder", code))
        }
        out.append(Line("Path check", area.components(of: area.targetsURL) == ["targets.json"] ? "ok" : "refused"))
        out.append(Line("Index file", folderPresent ? indexFile(area) : (folderRefused ? "refused" : "missing")))

        if let s = ShareTargetIndex.PublishStatus.read(from: area) {
            out.append(Line("Last app publish", "\(stamp(Date(timeIntervalSince1970: s.at))): \(s.result), \(s.targets) targets"))
        } else {
            out.append(Line("Last app publish", "no record"))
        }

        do {
            let file = try ShareTargetIndex.readFile(from: area, allowStale: true)
            let demo = file.targets.filter { $0.realm == "demo" }.count
            let stale = file.stale.map { ", stale: \(ShareTargetIndex.sanitizeCode($0))" } ?? ""
            out.append(Line("Index decode", "ok, version \(file.version), \(file.targets.count) targets (\(demo) Demo)\(stale)"))
        } catch {
            out.append(Line("Index decode", code(error)))
        }

        // Probe only an existing folder: the probe creates the lock file, never the share folder itself.
        out.append(Line("Tombstone lock", !folderPresent ? "skipped (no share folder)" : lockProbe(area, timeout: lockTimeout)))
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
        (error as? ShareError)?.code ?? "other"
    }

    static func fsCode(_ error: Error, missing: String) -> String {
        switch error {
        case ShareFS.ReadFailure.notFound: missing
        case ShareFS.ReadFailure.io(ELOOP): "refused (link)"
        case ShareFS.ReadFailure.io(ENOTDIR): "refused (link or not a folder)"   // O_DIRECTORY|O_NOFOLLOW on a link
        case let f as ShareFS.ReadFailure: f.code
        default: "refused"
        }
    }

    static func indexFile(_ area: ShareArea) -> String {
        do {
            let (dir, name) = try area.openParent(area.targetsURL)
            let fd = try ShareFS.openFile(dir, name)
            defer { close(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0 else { return "stat failed \(errno)" }
            guard (st.st_mode & S_IFMT) == S_IFREG else { return "refused (not a regular file)" }
            let date = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            return "\(st.st_size) bytes, modified \(stamp(date)), protection \(protection(fd: fd))"
        } catch {
            return fsCode(error, missing: "missing")
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

    /// Data protection class of an open descriptor (iOS); "n/a" elsewhere.
    static func protection(fd: Int32) -> String {
        #if os(iOS)
        let c = fcntl(fd, F_GETPROTECTIONCLASS)
        switch c {
        case 1: return "Complete (A)"
        case 2: return "CompleteUnlessOpen (B)"
        case 3: return "CompleteUntilFirstUserAuthentication (C)"
        case 4: return "None (D)"
        case -1: return "unknown (errno \(errno))"
        default: return "class \(c)"
        }
        #else
        return "n/a"
        #endif
    }

    static func stamp(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
}
