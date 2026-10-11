import Foundation
import Testing
@testable import OrchShareStaging

/// A path component is swapped for a symbolic link between two steps of the descriptor walk (the walk's test hook
/// pauses right after component N was opened). The operation must fail or stay inside the share root; the tree the
/// link points to is never read, listed, renamed or deleted.
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
            if k < 2 { #expect(!moved) }   // a swapped directory component fails the walk; a swapped leaf may only move the link itself
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
}
