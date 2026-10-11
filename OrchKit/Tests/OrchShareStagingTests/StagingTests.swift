import Foundation
import Testing
import OrchStore
@testable import OrchShareStaging

let WS = String(repeating: "a", count: 32)
let WS2 = String(repeating: "b", count: 32)

func tmp() -> URL {
    // NSTemporaryDirectory is inside the hosted simulator app's forbidden home directory.
    // The simulator's shared /tmp is outside both home and the fixture App Group roots.
    let u = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().appendingPathComponent("orchshare-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

func target(_ ws: String = WS, realm: String = "live", generation: Int64 = 1) -> ShareTarget {
    ShareTarget(realm: realm, ws: ws, name: "Laptop", hue: 2, generation: generation)
}

func sourceFile(_ bytes: Int, in dir: URL, name: String = "a.bin") -> URL {
    let u = dir.appendingPathComponent(name)
    FileManager.default.createFile(atPath: u.path, contents: Data(repeating: 0x41, count: bytes))
    return u
}

func names(_ dir: URL) -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()) ?? [] }

struct StagingTests {
    @Test func stagesFileTextAndURLWithReadyMarkerLast() throws {
        let base = tmp(); let area = ShareArea(shareGroupRoot: base)
        let s = try StagingSession(area: area, target: target())
        try s.add(.file(sourceFile(1000, in: tmp()), name: "../../etc/pass\nwd.txt", type: "public.plain-text"))
        try s.add(.text("hello"))
        try s.add(.url("https://example.invalid/x?y=1"))
        // Not visible to the app before commit.
        #expect(ShareInbox(area: area).peekReady().isEmpty)
        let id = try s.commit(note: "  look  ")
        let jobs = ShareInbox(area: area).peekReady()
        #expect(jobs.count == 1)
        let m = jobs[0].manifest
        #expect(m.jobID == id && m.note == "look" && m.items.count == 3 && m.totalBytes == 1000 + 5 + 29)
        #expect(m.items[0].name == "passwd.txt")  // path components and control characters never survive
        #expect(m.items.map(\.kind) == [.file, .text, .url])
        #expect(names(jobs[0].dir) == ["READY", "item-1", "item-2", "item-3", "manifest.json"])
        #expect(try Data(contentsOf: jobs[0].dir.appendingPathComponent("item-2")) == Data("hello".utf8))
    }

    @Test func pathMatchesStoreLayout() throws {
        let base = tmp()
        let layout = try StoreLayout(appRoot: base.appendingPathComponent("app"), pushGroupRoot: base.appendingPathComponent("push"),
                                     shareGroupRoot: base.appendingPathComponent("share"), realm: "live")
        let area = ShareArea(shareGroupRoot: base.appendingPathComponent("share"))
        #expect(try area.stagingDir(realm: "live", ws: WS).path == layout.stagedJobsDir(WS).path)
        #expect(try area.quarantineDir(realm: "live", ws: WS).path == layout.quarantineDir(WS).path)
        #expect(area.shareDir.path == layout.shareDir.path)
        for bad in ["", "Live", "a/b", ".."] { #expect(throws: (any Error).self) { try area.stagingDir(realm: bad, ws: WS) } }
        for bad in ["", "A", String(repeating: "g", count: 32), String(repeating: "a", count: 31)] {
            #expect(throws: (any Error).self) { try area.stagingDir(realm: "live", ws: bad) }
            #expect(throws: (any Error).self) { try StoreLayout.validate(ws: bad) }
        }
    }

    @Test func limitsAreEnforcedOnBytesActuallyRead() throws {
        let base = tmp(); let area = ShareArea(shareGroupRoot: base)
        let s = try StagingSession(area: area, target: target())
        try s.add(.file(sourceFile(ShareLimits.maxTotalBytes - 10, in: tmp()), name: "big", type: nil))
        // Total would exceed 25 MiB: refused, partial file removed, earlier item kept.
        #expect(throws: ShareError.tooLarge) { try s.add(.file(sourceFile(11, in: tmp(), name: "b"), name: "b", type: nil)) }
        #expect(throws: ShareError.tooLarge) { try s.add(.text(String(repeating: "x", count: 11))) }
        try s.add(.text(String(repeating: "x", count: 10)))
        #expect(names(try area.stagingDir(realm: "live", ws: WS).appendingPathComponent(s.id)).filter { $0.hasPrefix("item-") } == ["item-1", "item-2"])
        let fresh = try StagingSession(area: area, target: target())
        for i in 0..<5 { try fresh.add(.text("n\(i)")) }
        #expect(throws: ShareError.tooManyItems) { try fresh.add(.text("six")) }
    }

    @Test func rejectsUnsupportedInputs() throws {
        let base = tmp(); let area = ShareArea(shareGroupRoot: base)
        let s = try StagingSession(area: area, target: target())
        #expect(throws: ShareError.unsupported("not a regular file")) { try s.add(.file(base, name: "dir", type: nil)) }
        let link = tmp().appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sourceFile(3, in: tmp()))
        #expect(throws: ShareError.unsupported("not a regular file")) { try s.add(.file(link, name: "link", type: nil)) }
        #expect(throws: ShareError.unsupported("url")) { try s.add(.url("not a url")) }
        #expect(throws: ShareError.unsupported("url")) { try s.add(.url("https://a.invalid/\u{0007}")) }
        #expect(throws: ShareError.empty) { try s.add(.text("")) }
        #expect(throws: ShareError.empty) { try s.commit(note: nil) }
    }

    @Test func cancelRemovesPartialCopies() throws {
        let base = tmp(); let area = ShareArea(shareGroupRoot: base)
        let s = try StagingSession(area: area, target: target())
        try s.add(.file(sourceFile(100, in: tmp()), name: "a", type: nil))
        s.cancel()
        #expect(names(try area.stagingDir(realm: "live", ws: WS)).isEmpty)
        #expect(throws: ShareError.cancelled) { try s.commit(note: nil) }
        #expect(ShareInbox(area: area).peekReady().isEmpty)
    }

    @Test func tombstonedDestinationWritesNothing() throws {
        let base = tmp(); let area = ShareArea(shareGroupRoot: base)
        try area.coordination.write(TombstoneRecord(realm: "live", ws: WS, generation: 1))
        let s = try StagingSession(area: area, target: target())
        #expect(throws: ShareError.destinationRemoved) { try s.add(.text("late")) }
        #expect(!FileManager.default.fileExists(atPath: area.stagingRoot.path))
        // A later generation is a different, live destination.
        let g2 = try StagingSession(area: area, target: target(generation: 2))
        try g2.add(.text("ok")); try g2.commit(note: nil)
    }

    @Test func wipeBetweenAddAndCommitLeavesNothingReady() throws {
        let base = tmp(); let area = ShareArea(shareGroupRoot: base)
        let s = try StagingSession(area: area, target: target())
        try s.add(.text("one"))
        // The wipe publishes the tombstone, then purges staged jobs (phase 3).
        try area.coordination.write(TombstoneRecord(realm: "live", ws: WS, generation: 1))
        ShareInbox(area: area).purge(realm: "live", ws: WS)
        #expect(throws: ShareError.destinationRemoved) { try s.commit(note: nil) }
        #expect(names(try area.stagingDir(realm: "live", ws: WS)).isEmpty)
    }

    @Test func unreadableTombstonesFailClosed() throws {
        let base = tmp(); let area = ShareArea(shareGroupRoot: base)
        try FileManager.default.createDirectory(at: area.shareDir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: area.shareDir.appendingPathComponent("tombstones.json"))
        let s = try StagingSession(area: area, target: target())
        #expect(throws: ShareError.destinationRemoved) { try s.add(.text("x")) }
        #expect(names(area.shareDir).contains("staging") == false)
    }

    @Test func concurrentWipeNeverLeavesAReadyJob() async throws {
        // Many stagers race a wipe (tombstone, then purge). After the wipe completes no READY job may exist.
        let base = tmp(); let area = ShareArea(shareGroupRoot: base)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    guard let s = try? StagingSession(area: area, target: target()) else { return }
                    for _ in 0..<3 where (try? s.add(.text("t\(i)"))) != nil { }
                    _ = try? s.commit(note: nil)
                }
            }
            group.addTask {
                try? area.coordination.write(TombstoneRecord(realm: "live", ws: WS, generation: 1))
                ShareInbox(area: area).purge(realm: "live", ws: WS)
            }
        }
        #expect(ShareInbox(area: area).peekReady().isEmpty)
    }
}

struct InboxTests {
    func staged(_ area: ShareArea, _ t: ShareTarget, now: Date = Date()) throws -> String {
        let s = try StagingSession(area: area, target: t, now: { now })
        try s.add(.text("hello")); return try s.commit(note: nil)
    }

    @Test func temporarilyUnavailableDestinationStaysStaged() throws {
        let area = ShareArea(shareGroupRoot: tmp()), destination = LiveDestination(realm: "live", ws: WS, generation: 1)
        let id = try staged(area, target()), inbox = ShareInbox(area: area)
        #expect(inbox.claim(live: [], deferred: [destination]) == ClaimResult())
        #expect(inbox.peekReady().map(\.manifest.jobID) == [id])
        #expect(inbox.quarantined().isEmpty)
        #expect(inbox.claim(live: [destination]).claimed.map(\.manifest.jobID) == [id])
    }

    @Test func claimsLiveJobsAndQuarantinesOrphans() throws {
        let base = tmp(); let area = ShareArea(shareGroupRoot: base); let inbox = ShareInbox(area: area)
        let live = try staged(area, target())
        let gone = try staged(area, target(WS2))
        let stale = try staged(area, target(generation: 0))  // staged for an older generation of a live workspace
        let result = inbox.claim(live: [LiveDestination(realm: "live", ws: WS, generation: 1)])
        #expect(result.claimed.map(\.manifest.jobID) == [live])
        #expect(Set(result.quarantined.map(\.manifest.jobID)) == [gone, stale])
        // Nothing was redirected: the quarantined job still names its original destination.
        #expect(inbox.quarantined().contains { $0.manifest.jobID == gone && $0.manifest.ws == WS2 })
        // A second claim finds the already-claimed job (crash before import) and does not duplicate it.
        let again = inbox.claim(live: [LiveDestination(realm: "live", ws: WS, generation: 1)])
        #expect(again.claimed.map(\.manifest.jobID) == [live] && again.quarantined.isEmpty)
        inbox.complete(result.claimed[0])
        #expect(inbox.peekReady().isEmpty)
        #expect(inbox.claim(live: []) == ClaimResult())
    }

    @Test func redirectIsAnExplicitMoveAndPurgeWipesQuarantine() throws {
        let base = tmp(); let area = ShareArea(shareGroupRoot: base); let inbox = ShareInbox(area: area)
        let id = try staged(area, target(WS2))
        let q = inbox.claim(live: []).quarantined[0]
        let moved = try inbox.redirect(q, to: LiveDestination(realm: "live", ws: WS, generation: 1))
        #expect(moved.manifest.ws == WS && moved.manifest.jobID == id)
        #expect(inbox.quarantined().isEmpty)
        let claimed = inbox.claim(live: [LiveDestination(realm: "live", ws: WS, generation: 1)]).claimed
        #expect(claimed.count == 1)
        inbox.complete(claimed[0])
        // Quarantine does not survive a workspace wipe.
        _ = try staged(area, target(WS2))
        _ = inbox.claim(live: [])
        #expect(inbox.quarantined().count == 1)
        inbox.purge(realm: "live", ws: WS2)
        #expect(inbox.quarantined().isEmpty)
    }

    @Test func rejectsManifestThatDisagreesWithItsPath() throws {
        let base = tmp(); let area = ShareArea(shareGroupRoot: base); let inbox = ShareInbox(area: area)
        let id = try staged(area, target())
        let dir = try area.stagingDir(realm: "live", ws: WS).appendingPathComponent(id)
        var m = try JSONDecoder().decode(JobManifest.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        m.ws = WS2
        try JSONEncoder().encode(m).write(to: dir.appendingPathComponent("manifest.json"))
        #expect(inbox.peekReady().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func janitorExpiresStaleJobsAndPartials() throws {
        let base = tmp(); let area = ShareArea(shareGroupRoot: base); let inbox = ShareInbox(area: area)
        let now = Date()
        let old = try staged(area, target(), now: now.addingTimeInterval(-8 * 86_400))
        let fresh = try staged(area, target(), now: now.addingTimeInterval(-86_400))
        let quarantined = try staged(area, target(WS2), now: now.addingTimeInterval(-8 * 86_400))
        _ = inbox.claim(live: [LiveDestination(realm: "live", ws: WS, generation: 1)])  // claims old+fresh, quarantines WS2
        // A partial job from a killed extension (never READY), backdated two hours.
        let partial = try StagingSession(area: area, target: target(), jobID: "11111111-1111-4111-8111-111111111111")
        try partial.add(.text("x"))
        let pdir = try area.stagingDir(realm: "live", ws: WS).appendingPathComponent("11111111-1111-4111-8111-111111111111")
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-7200)], ofItemAtPath: pdir.path)
        // A young partial is a running extension: untouched.
        let young = try StagingSession(area: area, target: target(), jobID: "22222222-2222-4222-8222-222222222222")
        try young.add(.text("y"))
        #expect(inbox.sweep(now: now) == 3)
        let left = names(try area.stagingDir(realm: "live", ws: WS))
        #expect(left.sorted() == [fresh + ".claimed", "22222222-2222-4222-8222-222222222222"].sorted())
        #expect(!left.contains(old + ".claimed") && inbox.quarantined().isEmpty)
        _ = quarantined
    }
}

struct TargetIndexTests {
    @Test func publishLoadRoundTripAndFailClosed() throws {
        let base = tmp(); let area = ShareArea(shareGroupRoot: base)
        #expect(throws: ShareError.noWorkspaces) { try ShareTargetIndex.load(from: area) }
        try ShareTargetIndex.publish([target(), target(WS2)], to: area)
        #expect(try ShareTargetIndex.load(from: area).map(\.ws) == [WS, WS2])
        // Removed destinations disappear from the list.
        try area.coordination.write(TombstoneRecord(realm: "live", ws: WS, generation: 1))
        #expect(try ShareTargetIndex.load(from: area).map(\.ws) == [WS2])
        try area.coordination.write(TombstoneRecord(realm: "live", ws: WS2, generation: 1))
        #expect(throws: ShareError.noWorkspaces) { try ShareTargetIndex.load(from: area) }
        // Corrupt or invalid index: unreadable.
        try Data("garbage".utf8).write(to: area.targetsURL)
        #expect(throws: ShareError.unreadable) { try ShareTargetIndex.load(from: area) }
        #expect(throws: ShareError.self) { try ShareTargetIndex.publish([ShareTarget(realm: "live", ws: "../x", name: "n", hue: 0, generation: 1)], to: area) }
    }

    @Test func emptyIndexMeansNoWorkspaces() throws {
        let base = tmp(); let area = ShareArea(shareGroupRoot: base)
        try ShareTargetIndex.publish([], to: area)
        #expect(throws: ShareError.noWorkspaces) { try ShareTargetIndex.load(from: area) }
    }
}
