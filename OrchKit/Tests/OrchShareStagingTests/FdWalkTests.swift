import Foundation
import Testing
@testable import OrchShareStaging

/// A path component is swapped for a symbolic link between two steps of the descriptor walk (the walk's test hook
/// pauses right after component N was opened). The operation must fail or stay inside the share root; the tree the
/// link points to is never read, listed, renamed or deleted.
#if DEBUG
@Suite(.serialized) struct FdWalkTests {
    final class Fixture: @unchecked Sendable {
        let area: ShareArea
        let outside: URL        // mirrors <realm>/<ws>/<job>/ with a secret
        let jobID: String
        let jobDir: URL
        let wsDir: URL
        let rootPath: String
        private let lock = NSLock()
        private var fired = false
        init() throws {
            let base = tmp()
            area = ShareArea(shareGroupRoot: base.appendingPathComponent("group", isDirectory: true))
            let s = try StagingSession(area: area, target: target())
            try s.add(.text("INSIDE")); try s.commit(note: nil)
            jobID = s.id
            wsDir = try area.stagingDir(realm: "live", ws: WS)
            jobDir = wsDir.appendingPathComponent(jobID, isDirectory: true)
            outside = base.appendingPathComponent("outside", isDirectory: true)
            let od = outside.appendingPathComponent("live/\(WS)/\(jobID)", isDirectory: true)
            try FileManager.default.createDirectory(at: od, withIntermediateDirectories: true)
            try Data("OUTSIDE-SECRET".utf8).write(to: od.appendingPathComponent("item-1"))
            try Data("x".utf8).write(to: od.appendingPathComponent("READY"))
            rootPath = area.shareDir.standardizedFileURL.path
        }
        /// After component `index` of the walk was opened, replace `entry` (a path below the share dir) with a link to `target`.
        func armSwap(afterComponent index: Int, replace entry: URL, with target: URL) {
            let root = rootPath
            ShareFS.setWalkHook { [self] r, i, _ in
                guard r == root, i == index else { return }
                lock.lock(); defer { lock.unlock() }
                guard !fired else { return }
                fired = true
                let moved = entry.deletingLastPathComponent().appendingPathComponent(entry.lastPathComponent + ".moved")
                try? FileManager.default.moveItem(at: entry, to: moved)
                try? FileManager.default.createSymbolicLink(at: entry, withDestinationURL: target)
            }
        }
        var didFire: Bool { lock.lock(); defer { lock.unlock() }; return fired }
        func disarm() { ShareFS.setWalkHook(nil) }
        func outsideIntact() -> Bool {
            let od = outside.appendingPathComponent("live/\(WS)/\(jobID)")
            return (try? Data(contentsOf: od.appendingPathComponent("item-1"))) == Data("OUTSIDE-SECRET".utf8)
                && FileManager.default.fileExists(atPath: od.appendingPathComponent("READY").path)
        }
    }

    /// (component index after which to swap, entry to replace, link target relative to outside)
    static func swaps(_ f: Fixture) -> [(Int, URL, URL)] {
        let realmDir = f.wsDir.deletingLastPathComponent()
        return [
            (1, realmDir, f.outside.appendingPathComponent("live")),                               // staging opened, realm swapped
            (2, f.wsDir, f.outside.appendingPathComponent("live/\(WS)")),                          // realm opened, ws swapped
            (3, f.jobDir, f.outside.appendingPathComponent("live/\(WS)/\(f.jobID)")),              // ws opened, job swapped
        ]
    }

    @Test func readNeverFollowsASwappedComponent() throws {
        for k in 0..<3 {
            let f = try Fixture(); let (idx, entry, dest) = Self.swaps(f)[k]
            f.armSwap(afterComponent: idx, replace: entry, with: dest)
            defer { f.disarm() }
            let item = StagedItem(name: "n", kind: .text, type: nil, bytes: 6, file: "item-1")
            let job = StagedJob(manifest: JobManifest(jobID: f.jobID, realm: "live", ws: WS, generation: 1, createdAt: 0, note: nil, items: [item]), dir: f.jobDir)
            #expect(ShareInbox(area: f.area).text(of: item, in: job) == nil)
            #expect(f.didFire)
            #expect(f.outsideIntact())
        }
    }

    @Test func listNeverFollowsASwappedComponent() throws {
        for k in 0..<3 {
            let f = try Fixture(); let (idx, entry, dest) = Self.swaps(f)[k]
            f.armSwap(afterComponent: idx, replace: entry, with: dest)
            defer { f.disarm() }
            let listed = f.area.listNames(f.jobDir)
            #expect(listed.isEmpty)
            #expect(f.didFire)
            #expect(f.outsideIntact())
        }
    }

    @Test func moveNeverFollowsASwappedComponent() throws {
        for k in 0..<3 {
            let f = try Fixture(); let (idx, entry, dest) = Self.swaps(f)[k]
            f.armSwap(afterComponent: idx, replace: entry, with: dest)
            defer { f.disarm() }
            let claimed = f.wsDir.appendingPathComponent(f.jobID + ".claimed", isDirectory: true)
            let moved = f.area.rename(f.jobDir, to: claimed)
            f.disarm()
            #expect(f.didFire)
            #expect(f.outsideIntact())
            let outsideClaimed = f.outside.appendingPathComponent("live/\(WS)/\(f.jobID).claimed")
            #expect(!FileManager.default.fileExists(atPath: outsideClaimed.path))
            // k == 0 and k == 1 swap a directory component the walk must traverse: the walk fails, nothing moves.
            // k == 2 swaps the leaf (the job directory itself): renameat does not follow a final link, so the rename
            // may succeed, but then it moves the link entry inside the share area, never the outside tree.
            if k < 2 { #expect(!moved) }
            _ = moved
        }
    }

    @Test func removeNeverFollowsASwappedComponent() throws {
        for k in 0..<3 {
            let f = try Fixture(); let (idx, entry, dest) = Self.swaps(f)[k]
            f.armSwap(afterComponent: idx, replace: entry, with: dest)
            defer { f.disarm() }
            _ = f.area.safeRemove(f.jobDir)
            f.disarm()
            #expect(f.didFire)
            #expect(f.outsideIntact())
        }
    }

    @Test func removeUnlinksALeafLinkWithoutTouchingItsTarget() throws {
        let f = try Fixture()
        let link = f.wsDir.appendingPathComponent("evil")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.outside)
        #expect(f.area.safeRemove(link))
        #expect(!ShareArea.exists(link))
        #expect(f.outsideIntact())
    }

    @Test func recursiveRemoveDoesNotFollowNestedLinks() throws {
        let f = try Fixture()
        try FileManager.default.createSymbolicLink(at: f.jobDir.appendingPathComponent("nested"), withDestinationURL: f.outside)
        #expect(f.area.safeRemove(f.jobDir))
        #expect(!ShareArea.exists(f.jobDir))
        #expect(f.outsideIntact())
    }

    @Test func walkRefusesDotComponentsAndOutsideUrls() throws {
        let f = try Fixture()
        #expect(f.area.components(of: f.outside) == nil)
        #expect(throws: (any Error).self) { try ShareFS.checkName("..") }
        #expect(throws: (any Error).self) { try ShareFS.checkName("a/b") }
        #expect(throws: (any Error).self) { try ShareFS.checkName("") }
    }

    // MARK: create:true walks

    @Test func createWalksNeverFollowASwappedComponent() throws {
        // writeFile
        do {
            let f = try Fixture(); let (idx, entry, dest) = Self.swaps(f)[0]
            f.armSwap(afterComponent: idx, replace: entry, with: dest); defer { f.disarm() }
            #expect(throws: (any Error).self) { try f.area.writeFile(Data("x".utf8), to: f.wsDir.appendingPathComponent("new.json")) }
            #expect(f.didFire)
            #expect(!ShareArea.exists(f.outside.appendingPathComponent("live/\(WS)/new.json")))
            #expect(f.outsideIntact())
        }
        // ensureDirectory
        do {
            let f = try Fixture(); let (idx, entry, dest) = Self.swaps(f)[1]
            f.armSwap(afterComponent: idx, replace: entry, with: dest); defer { f.disarm() }
            #expect(throws: (any Error).self) { try f.area.ensureDirectory(f.wsDir.appendingPathComponent("sub")) }
            #expect(!ShareArea.exists(f.outside.appendingPathComponent("live/\(WS)/sub")))
        }
        // Stager (openDir create:true)
        do {
            let f = try Fixture(); let (idx, entry, dest) = Self.swaps(f)[0]
            let s = try StagingSession(area: f.area, target: target())
            f.armSwap(afterComponent: idx, replace: entry, with: dest); defer { f.disarm() }
            #expect(throws: (any Error).self) { try s.add(.text("LEAK")) }
            #expect(f.didFire)
            #expect(names(f.outside.appendingPathComponent("live/\(WS)")) == [f.jobID])
            #expect(f.outsideIntact())
        }
        // redirect (quarantined job to another workspace)
        do {
            let f = try Fixture()
            let inbox = ShareInbox(area: f.area)
            _ = inbox.claim(live: [])
            let q = try #require(inbox.quarantined().first)
            let (idx, entry, dest) = Self.swaps(f)[0]
            f.armSwap(afterComponent: idx, replace: entry, with: dest); defer { f.disarm() }
            #expect(throws: (any Error).self) { try inbox.redirect(q, to: LiveDestination(realm: "live", ws: WS2, generation: 1)) }
            #expect(f.didFire)
            #expect(!ShareArea.exists(f.outside.appendingPathComponent("live/\(WS2)")))
            #expect(f.outsideIntact())
        }
    }

    @Test func swapToARealDirectoryInsideTheRootIsAllowed() throws {
        // Positive control: the walk only refuses links. A real directory swapped in is still inside the share area.
        let f = try Fixture()
        let root = f.rootPath, job = f.jobDir
        ShareFS.setWalkHook { r, i, _ in
            guard r == root, i == 3 else { return }
            let moved = job.deletingLastPathComponent().appendingPathComponent("moved-away")
            try? FileManager.default.moveItem(at: job, to: moved)
            try? FileManager.default.createDirectory(at: job, withIntermediateDirectories: false)
            try? Data("SWAPPED-INSIDE".utf8).write(to: job.appendingPathComponent("item-1"))
        }
        defer { f.disarm() }
        #expect(try f.area.readFile(job.appendingPathComponent("item-1"), cap: 100) == Data("SWAPPED-INSIDE".utf8))
    }

    // MARK: descriptors

    /// Descriptors whose path lies under `prefix` (other suites run in parallel, so the process-wide count is noisy).
    static func openDescriptorCount(under prefix: String) -> Int {
        (0..<1024).filter { fd in
            guard fcntl(Int32(fd), F_GETFD) != -1 else { return false }
            var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(Int32(fd), F_GETPATH, &buf) == 0 else { return false }
            return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).contains(prefix)
        }.count
    }

    @Test func noDescriptorsLeakAcrossManyCyclesIncludingFailures() throws {
        let f = try Fixture()
        let marker = f.outside.deletingLastPathComponent().lastPathComponent
        let before = Self.openDescriptorCount(under: marker)
        for i in 0..<200 {
            _ = try? f.area.readFile(f.jobDir.appendingPathComponent("item-1"), cap: 100)
            _ = try? f.area.readFile(f.jobDir.appendingPathComponent("missing"), cap: 100)
            _ = f.area.listNames(f.jobDir)
            try f.area.writeFile(Data("x".utf8), to: f.wsDir.appendingPathComponent("w\(i % 3).json"))
            _ = f.area.rename(f.wsDir.appendingPathComponent("w0.json"), to: f.wsDir.appendingPathComponent("w9.json"))
            _ = f.area.safeRemove(f.wsDir.appendingPathComponent("w9.json"))
            _ = f.area.listNames(f.outside)   // outside the share dir: refused
        }
        #expect(before == 0)
        #expect(Self.openDescriptorCount(under: marker) == 0)
    }

    // MARK: backup exclusion

    @Test func createdDirectoriesAreExcludedFromBackup() throws {
        let f = try Fixture()
        let dir = f.area.shareDir.appendingPathComponent("fresh/deeper", isDirectory: true)
        try f.area.ensureDirectory(dir)
        for d in [dir, dir.deletingLastPathComponent()] {
            #expect(try d.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
            #expect(getxattr(d.path, ShareFS.backupExcludeAttr, nil, 0, 0, 0) > 0)
        }
        // Byte-for-byte what Foundation writes for the same directory.
        let ref = f.area.shareDir.appendingPathComponent("foundation-ref", isDirectory: true)
        try FileManager.default.createDirectory(at: ref, withIntermediateDirectories: false)
        var u = ref; var rv = URLResourceValues(); rv.isExcludedFromBackup = true; try u.setResourceValues(rv)
        func attr(_ p: String) -> [UInt8] {
            var b = [UInt8](repeating: 0, count: 256)
            let n = getxattr(p, ShareFS.backupExcludeAttr, &b, b.count, 0, 0)
            return n > 0 ? Array(b.prefix(n)) : []
        }
        #expect(!attr(ref.path).isEmpty)
        #expect(attr(dir.path) == attr(ref.path))
    }
}
#endif
