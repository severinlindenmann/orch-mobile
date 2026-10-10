import Foundation
import Testing
import OrchStore
import OrchCoordination
@testable import OrchShareStaging

struct AdversarialTests {
    // Confused deputy at library level: a file URL pointing into the share group (another workspace's staged plaintext) is copied.
    @Test func adv1_fileInsideShareGroupIsCopied() throws {
        let base = tmp(); let area = ShareArea(shareGroupRoot: base)
        let a = try StagingSession(area: area, target: target(WS2))
        try a.add(.text("SECRET-OTHER-WS")); try a.commit(note: nil)
        let victim = ShareInbox(area: area).peekReady()[0]
        let secretURL = victim.dir.appendingPathComponent("item-1")
        let s = try StagingSession(area: area, target: target(WS))
        // Fixed behaviour: neither the strict file path nor the provider-copy path may read the share group.
        #expect(throws: ShareError.unsupported("source not allowed")) { try s.add(.file(secretURL, name: "x.txt", type: "public.plain-text")) }
        #expect(throws: ShareError.unsupported("source not allowed")) { try s.add(.providerCopy(secretURL, name: "x.txt", type: nil)) }
        #expect(ShareInbox(area: area).peekReady().filter { $0.manifest.ws == WS }.isEmpty)
    }
    @Test func adv1b_targetsAndTombstonesCopied() throws {
        let base = tmp(); let area = ShareArea(shareGroupRoot: base)
        try ShareTargetIndex.publish([target(WS)], to: area)
        let s = try StagingSession(area: area, target: target(WS))
        #expect(throws: (any Error).self) { try s.add(.file(area.targetsURL, name: "t", type: nil)) }
    }
    // Manifest jobID traversal on quarantine.
    @Test func adv2_jobIDTraversalOnQuarantine() throws {
        let base = tmp(); let area = ShareArea(shareGroupRoot: base)
        try ShareTargetIndex.publish([target(WS)], to: area)
        #expect(throws: ShareError.self) { try StagingSession(area: area, target: target(WS2), jobID: "../../../targets.json") }
        for bad in ["", "A", "../x", "11111111-1111-4111-8111-11111111111Z", "11111111-1111-4111-8111-11111111111A"] {
            #expect(throws: ShareError.self) { try StagingSession(area: area, target: target(WS2), jobID: bad) }
        }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: area.targetsURL.path, isDirectory: &isDir)
        #expect(!isDir.boolValue)
    }
    // Manifest jobID crafted by a writer of the group (constructor path not used).
    @Test func adv2b_manifestJobIDTraversal() throws {
        let base = tmp(); let area = ShareArea(shareGroupRoot: base)
        try ShareTargetIndex.publish([target(WS)], to: area)
        let s = try StagingSession(area: area, target: target(WS2))
        try s.add(.text("x")); try s.commit(note: nil)
        let job = ShareInbox(area: area).peekReady()[0]
        var m = job.manifest; m.jobID = "../../../targets.json"
        try JSONEncoder().encode(m).write(to: job.dir.appendingPathComponent("manifest.json"))
        _ = ShareInbox(area: area).claim(live: [])
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: area.targetsURL.path, isDirectory: &isDir)
        #expect(!isDir.boolValue, "manifest jobID traversal replaced targets.json")
    }
    // Symlinked realm dir: app follows it and deletes outside the share area on complete().
    @Test func adv3_symlinkRealmFollowed() throws {
        let base = tmp(); let area = ShareArea(shareGroupRoot: base)
        let outside = tmp()
        let s = try StagingSession(area: area, target: target(WS))
        try s.add(.text("x")); try s.commit(note: nil)
        let job = ShareInbox(area: area).peekReady()[0]
        // move the real realm dir outside and symlink it back
        let realmDir = area.stagingRoot.appendingPathComponent("live")
        let moved = outside.appendingPathComponent("live")
        try FileManager.default.moveItem(at: realmDir, to: moved)
        try FileManager.default.createSymbolicLink(at: realmDir, withDestinationURL: moved)
        let seen = ShareInbox(area: area).peekReady()
        print("ADV3 jobs via symlinked realm:", seen.count, "job", job.manifest.jobID)
        #expect(seen.isEmpty, "inbox traverses a symlinked realm directory")
    }
    @Test func adv4_controlAndBidiStripped() {
        let n = StagingSession.clean("invoice\u{202E}txt.exe", fallback: "F")
        print("ADV4:", n.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " "))
        #expect(!n.unicodeScalars.contains { $0.value == 0x202E })
        let long = StagingSession.clean(String(repeating: "a\u{0301}\u{0301}\u{0301}\u{0301}", count: 120), fallback: "F")
        print("ADV4 combining name scalars:", long.unicodeScalars.count)
    }
    @Test func adv5_fifoSourceRejected() throws {
        let base = tmp(); let area = ShareArea(shareGroupRoot: base)
        let f = base.appendingPathComponent("fifo"); mkfifo(f.path, 0o600)
        let s = try StagingSession(area: area, target: target(WS))
        #expect(throws: ShareError.self) { try s.add(.file(f, name: "f", type: nil)) }
        let l = base.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(at: l, withDestinationURL: sourceFile(10, in: tmp()))
        #expect(throws: ShareError.self) { try s.add(.file(l, name: "l", type: nil)) }
    }
    @Test func adv6_exactLimitAndOver() throws {
        let base = tmp(); let area = ShareArea(shareGroupRoot: base)
        let s = try StagingSession(area: area, target: target(WS))
        try s.add(.file(sourceFile(ShareLimits.maxTotalBytes, in: tmp()), name: "a", type: nil))
        #expect(throws: ShareError.tooLarge) { try s.add(.text("x")) }
        #expect(names(area.stagingRoot.appendingPathComponent("live/\(WS)/\(s.id)")) == ["item-1"])
    }
    @Test func adv7_wipeBetweenAddsBlocksFurtherWrites() throws {
        let base = tmp(); let area = ShareArea(shareGroupRoot: base)
        let s = try StagingSession(area: area, target: target(WS))
        try s.add(.text("x"))
        try area.coordination.write(TombstoneRecord(realm: "live", ws: WS, generation: 1))
        ShareInbox(area: area).purge(realm: "live", ws: WS)
        #expect(throws: ShareError.destinationRemoved) { try s.commit(note: nil) }
        #expect(!FileManager.default.fileExists(atPath: area.stagingRoot.appendingPathComponent("live/\(WS)").path))
    }
}

import UniformTypeIdentifiers

struct FixRoundTests {
    @Test func plainTextProviderCarryingAFileURLIsStagedAsText() async throws {
        let base = tmp(); let area = ShareArea(shareGroupRoot: base)
        let secret = sourceFile(40, in: base, name: "secret.txt")   // inside the share group root
        let provider = NSItemProvider(item: secret as NSURL, typeIdentifier: UTType.plainText.identifier)
        let s = try StagingSession(area: area, target: target())
        try await ProviderStager.stage(provider, into: s)
        try s.commit(note: nil)
        let job = ShareInbox(area: area).peekReady()[0]
        print("URL-as-text manifest:", job.manifest)
        let bytes = try Data(contentsOf: job.dir.appendingPathComponent("item-1"))
        print("URL-as-text item-1 bytes:", Array(bytes))
        let text = try #require(String(data: bytes, encoding: .utf8))
        #expect(job.manifest.items.map(\.kind) == [.text])
        #expect(text == secret.absoluteString)
        #expect(bytes != (try Data(contentsOf: secret)))
        #expect(!text.contains("AAAA"))
    }

    @Test func urlProviderWithFileURLIsText() async throws {
        let base = tmp(); let area = ShareArea(shareGroupRoot: base)
        let provider = NSItemProvider(item: sourceFile(5, in: base) as NSURL, typeIdentifier: UTType.url.identifier)
        let s = try StagingSession(area: area, target: target())
        try await ProviderStager.stage(provider, into: s)
        try s.commit(note: nil)
        #expect(ShareInbox(area: area).peekReady()[0].manifest.items.map(\.kind) == [.url])
    }

    @Test func fileURLOnlyProviderCopiesTheFileButNeverFromAContainer() async throws {
        let base = tmp(); let area = ShareArea(shareGroupRoot: base)
        let ok = sourceFile(77, in: tmp(), name: "doc.bin")
        let s = try StagingSession(area: area, target: target())
        try await ProviderStager.stage(NSItemProvider(item: ok as NSURL, typeIdentifier: UTType.fileURL.identifier), into: s)
        let inside = sourceFile(9, in: area.shareDir, name: "leak.bin")
        await #expect(throws: ShareError.unsupported("source not allowed")) {
            try await ProviderStager.stage(NSItemProvider(item: inside as NSURL, typeIdentifier: UTType.fileURL.identifier), into: s)
        }
        // An extra forbidden root (another App Group container) is refused too.
        let other = tmp()
        let s2 = try StagingSession(area: area, target: target(), extraForbiddenRoots: [other])
        let planted = sourceFile(3, in: other, name: "push-state")
        #expect(throws: ShareError.unsupported("source not allowed")) { try s2.add(.file(planted, name: "p", type: nil)) }
        #expect(throws: ShareError.unsupported("source not allowed")) { try s2.add(.providerCopy(planted, name: "p", type: nil)) }
        try s.commit(note: nil)
        let job = ShareInbox(area: area).peekReady()[0]
        #expect(job.manifest.items.count == 1 && job.manifest.items[0].bytes == 77)
    }

    @Test func extensionHomeIsForbiddenForFileURLsButNotProviderCopies() throws {
        let area = ShareArea(shareGroupRoot: tmp())
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let probe = home.appendingPathComponent(".orch-share-probe-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: probe.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: probe) }
        let s = try StagingSession(area: area, target: target())
        #expect(throws: ShareError.unsupported("source not allowed")) { try s.add(.file(probe, name: "p", type: nil)) }
        try s.add(.providerCopy(probe, name: "p", type: nil))  // the provider's temporary copy lives under the extension home
    }

    @Test func namesAreCappedByScalarsAndLoseFormatCharacters() {
        let long = StagingSession.clean(String(repeating: "a\u{0301}\u{0301}\u{0301}\u{0301}", count: 120), fallback: "F")
        #expect(long.unicodeScalars.count <= ShareLimits.maxNameCharacters)
        #expect(StagingSession.clean("a\u{200B}b\u{202E}c\u{2028}d", fallback: "F") == "abcd")
    }

    @Test func manifestWithBadPathsOrIdsIsDroppedNotFollowed() throws {
        let base = tmp(); let area = ShareArea(shareGroupRoot: base); let inbox = ShareInbox(area: area)
        let s = try StagingSession(area: area, target: target())
        try s.add(.text("x")); try s.commit(note: nil)
        let dir = try area.stagingDir(realm: "live", ws: WS).appendingPathComponent(s.id)
        var m = try JSONDecoder().decode(JobManifest.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        m.items = [StagedItem(name: "n", kind: .text, type: nil, bytes: 1, file: "../../targets.json")]
        try JSONEncoder().encode(m).write(to: dir.appendingPathComponent("manifest.json"))
        #expect(inbox.peekReady().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        // Directory name that differs from the job id is refused as well.
        let s2 = try StagingSession(area: area, target: target())
        try s2.add(.text("y")); try s2.commit(note: nil)
        let d2 = try area.stagingDir(realm: "live", ws: WS).appendingPathComponent(s2.id)
        try FileManager.default.moveItem(at: d2, to: d2.deletingLastPathComponent().appendingPathComponent(UUID().uuidString.lowercased()))
        #expect(inbox.peekReady().isEmpty)
    }

    @Test func textReadsRefuseSymlinksAndCapBytes() throws {
        let base = tmp(); let area = ShareArea(shareGroupRoot: base); let inbox = ShareInbox(area: area)
        let s = try StagingSession(area: area, target: target())
        try s.add(.text(String(repeating: "z", count: 100_000))); try s.commit(note: nil)
        let job = inbox.peekReady()[0]
        #expect(inbox.text(of: job.manifest.items[0], in: job)?.count == 16 * 1024)
        let item = job.dir.appendingPathComponent("item-1")
        try FileManager.default.removeItem(at: item)
        try FileManager.default.createSymbolicLink(at: item, withDestinationURL: sourceFile(5, in: tmp()))
        #expect(inbox.text(of: job.manifest.items[0], in: job) == nil)
    }

    @Test func claimOnlyTouchesTheCurrentRealm() throws {
        let area = ShareArea(shareGroupRoot: tmp()); let inbox = ShareInbox(area: area)
        for realm in ["demo", "live"] {
            let s = try StagingSession(area: area, target: target(realm: realm)); try s.add(.text(realm)); try s.commit(note: nil)
        }
        let r = inbox.claim(live: [LiveDestination(realm: "live", ws: WS, generation: 1)], realm: "live")
        #expect(r.claimed.count == 1 && r.quarantined.isEmpty)
        // The demo job is untouched (still ready, unclaimed, not quarantined).
        let demo = inbox.peekReady().filter { $0.manifest.realm == "demo" }
        #expect(demo.count == 1 && !demo[0].dir.lastPathComponent.hasSuffix(".claimed") && inbox.quarantined().isEmpty)
    }

    @Test func claimedJobsComeBackOnlyDuringRecovery() throws {
        let area = ShareArea(shareGroupRoot: tmp()); let inbox = ShareInbox(area: area)
        let s = try StagingSession(area: area, target: target()); try s.add(.text("a")); try s.commit(note: nil)
        let live: Set = [LiveDestination(realm: "live", ws: WS, generation: 1)]
        #expect(inbox.claim(live: live, realm: "live", includeClaimed: false).claimed.count == 1)
        #expect(inbox.claim(live: live, realm: "live", includeClaimed: false).claimed.isEmpty)   // active claim, not re-issued
        #expect(inbox.claim(live: live, realm: "live", includeClaimed: true).claimed.count == 1)  // startup recovery
    }

    @Test func importLedgerIsDurableAndBounded() {
        let inbox = ShareInbox(area: ShareArea(shareGroupRoot: tmp()))
        let id = UUID().uuidString.lowercased()
        #expect(!inbox.wasImported(id))
        inbox.markImported(id)
        #expect(inbox.wasImported(id) && ShareInbox(area: inbox.area).wasImported(id))
        for _ in 0..<520 { inbox.markImported(UUID().uuidString.lowercased()) }
        #expect(!inbox.wasImported(id))
    }

    // C1: an interruption between publishing the new job and deleting the original keeps everything recoverable.
    @Test func redirectInterruptedLeavesOriginalAndCollapsesOnClaim() throws {
        let area = ShareArea(shareGroupRoot: tmp()); let inbox = ShareInbox(area: area)
        let s = try StagingSession(area: area, target: target(WS2)); try s.add(.text("keep me")); let id = try s.commit(note: "n")
        let q = inbox.claim(live: []).quarantined[0]
        struct Boom: Error {}
        let dest = LiveDestination(realm: "live", ws: WS, generation: 1)
        #expect(throws: Boom.self) { try inbox.redirect(q, to: dest) { throw Boom() } }
        #expect(inbox.quarantined().map(\.manifest.jobID) == [id])                         // original intact
        let r = inbox.claim(live: [dest], realm: "live")
        #expect(r.claimed.map(\.manifest.jobID) == [id] && r.claimed[0].manifest.ws == WS)  // new job already visible
        #expect(inbox.quarantined().isEmpty)                                               // duplicate collapsed
        #expect(inbox.text(of: r.claimed[0].manifest.items[0], in: r.claimed[0]) == "keep me")
    }

    @Test func redirectBuildFailureLeavesOriginalAndNothingVisible() throws {
        let area = ShareArea(shareGroupRoot: tmp()); let inbox = ShareInbox(area: area)
        let s = try StagingSession(area: area, target: target(WS2)); try s.add(.text("x")); try s.commit(note: nil)
        let q = inbox.claim(live: []).quarantined[0]
        try FileManager.default.removeItem(at: q.dir.appendingPathComponent("item-1"))   // the copy step fails
        #expect(throws: (any Error).self) { try inbox.redirect(q, to: LiveDestination(realm: "live", ws: WS, generation: 1)) }
        #expect(inbox.quarantined().count == 1 && inbox.peekReady().isEmpty)
        #expect(names(try area.stagingDir(realm: "live", ws: WS)).isEmpty)
    }

    // C3: redirect is serialized with the wipe on the destination's generation.
    @Test func redirectToATombstonedDestinationIsRefused() throws {
        let area = ShareArea(shareGroupRoot: tmp()); let inbox = ShareInbox(area: area)
        let s = try StagingSession(area: area, target: target(WS2)); try s.add(.text("x")); try s.commit(note: nil)
        let q = inbox.claim(live: []).quarantined[0]
        try area.coordination.write(TombstoneRecord(realm: "live", ws: WS, generation: 1))
        #expect(throws: ShareError.destinationRemoved) { try inbox.redirect(q, to: LiveDestination(realm: "live", ws: WS, generation: 1)) }
        #expect(inbox.quarantined().count == 1)
        #expect(!FileManager.default.fileExists(atPath: area.stagingRoot.appendingPathComponent("live/\(WS)").path))
        // A newer generation of the same workspace is a different destination.
        _ = try inbox.redirect(q, to: LiveDestination(realm: "live", ws: WS, generation: 2))
    }

    @Test func concurrentRedirectAndWipeNeverLeaveAJobForARemovedDestination() async throws {
        let area = ShareArea(shareGroupRoot: tmp()); let inbox = ShareInbox(area: area)
        var quarantined: [StagedJob] = []
        for _ in 0..<12 {
            let s = try StagingSession(area: area, target: target(WS2)); try s.add(.text("x")); try s.commit(note: nil)
        }
        quarantined = inbox.claim(live: []).quarantined
        let dest = LiveDestination(realm: "live", ws: WS, generation: 1)
        await withTaskGroup(of: Void.self) { g in
            for q in quarantined { g.addTask { _ = try? inbox.redirect(q, to: dest) } }
            g.addTask {
                try? area.coordination.write(TombstoneRecord(realm: "live", ws: WS, generation: 1))
                _ = inbox.purgeTombstoned()
            }
        }
        _ = inbox.purgeTombstoned()   // the resumable pass after the wipe
        #expect(inbox.peekReady().filter { $0.manifest.ws == WS }.isEmpty)
    }

    // C2: the tombstone is the persisted cleanup record; purge is generation-aware and retried.
    @Test func purgeTombstonedIsGenerationAwareAndResumable() throws {
        let area = ShareArea(shareGroupRoot: tmp()); let inbox = ShareInbox(area: area)
        let old = try StagingSession(area: area, target: target(generation: 1)); try old.add(.text("a")); try old.commit(note: nil)
        let newer = try StagingSession(area: area, target: target(generation: 2)); try newer.add(.text("b")); try newer.commit(note: nil)
        let other = try StagingSession(area: area, target: target(WS2)); try other.add(.text("c")); try other.commit(note: nil)
        try area.coordination.write(TombstoneRecord(realm: "live", ws: WS, generation: 1))
        // Make the first attempt fail: the workspace directory cannot be modified.
        let wsDir = try area.stagingDir(realm: "live", ws: WS)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: wsDir.path)
        let first = inbox.purgeTombstoned()
        #expect(first.failed == 1 && first.removed == 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wsDir.path)
        let second = inbox.purgeTombstoned()
        #expect(second.failed == 0 && second.removed == 1)
        let left = inbox.peekReady().map { "\($0.manifest.ws.prefix(1))\($0.manifest.generation)" }.sorted()
        #expect(left == ["a2", "b1"])   // newer generation and other workspace untouched
    }
}

struct LinkAndNameTests {
    func staged(_ area: ShareArea, _ t: ShareTarget = target()) throws -> String {
        let s = try StagingSession(area: area, target: t); try s.add(.text("secret")); return try s.commit(note: nil)
    }
    func outsideFile() throws -> (URL, URL) {
        let dir = tmp(); let f = dir.appendingPathComponent("victim.txt")
        try Data("victim".utf8).write(to: f); return (dir, f)
    }
    let live: Set = [LiveDestination(realm: "live", ws: WS, generation: 1)]

    @Test func symlinkedJobDirIsNeverListedClaimedOrFollowed() throws {
        let area = ShareArea(shareGroupRoot: tmp()); let inbox = ShareInbox(area: area)
        let id = try staged(area)
        let wsDir = try area.stagingDir(realm: "live", ws: WS)
        let real = wsDir.appendingPathComponent(id)
        let outside = tmp().appendingPathComponent(id)
        try FileManager.default.moveItem(at: real, to: outside)
        try FileManager.default.createSymbolicLink(at: real, withDestinationURL: outside)
        #expect(inbox.peekReady().isEmpty)
        #expect(inbox.claim(live: live).claimed.isEmpty && inbox.claim(live: []).quarantined.isEmpty)
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("item-1").path))   // target untouched
        inbox.purge(realm: "live", ws: WS)  // removes the link, not the target
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("item-1").path))
    }

    @Test func symlinkedRealmOrWorkspaceDirIsNotTraversedOrPurgedThrough() throws {
        let area = ShareArea(shareGroupRoot: tmp()); let inbox = ShareInbox(area: area)
        _ = try staged(area)
        let realmDir = area.stagingRoot.appendingPathComponent("live")
        let outsideRoot = tmp()
        try FileManager.default.moveItem(at: realmDir, to: outsideRoot.appendingPathComponent("live"))
        try FileManager.default.createSymbolicLink(at: realmDir, withDestinationURL: outsideRoot.appendingPathComponent("live"))
        #expect(inbox.peekReady().isEmpty && inbox.claim(live: live).claimed.isEmpty)
        try area.coordination.write(TombstoneRecord(realm: "live", ws: WS, generation: 1))
        let r = inbox.purgeTombstoned()
        inbox.purge(realm: "live", ws: WS)
        inbox.sweep(now: Date().addingTimeInterval(30 * 86_400))
        #expect(r.removed == 0)
        // Everything the symlink pointed at survives.
        #expect(names(outsideRoot.appendingPathComponent("live/\(WS)")).count == 1)
        // A symlinked ws directory likewise.
        let area2 = ShareArea(shareGroupRoot: tmp()); let inbox2 = ShareInbox(area: area2)
        _ = try staged(area2)
        let ws2 = try area2.stagingDir(realm: "live", ws: WS)
        let out2 = tmp().appendingPathComponent("ws")
        try FileManager.default.moveItem(at: ws2, to: out2)
        try FileManager.default.createSymbolicLink(at: ws2, withDestinationURL: out2)
        #expect(inbox2.peekReady().isEmpty)
        inbox2.purge(realm: "live", ws: WS)
        #expect(names(out2).count == 1)
    }

    @Test func symlinkedStagingRootIsRefused() throws {
        let area = ShareArea(shareGroupRoot: tmp()); let inbox = ShareInbox(area: area)
        _ = try staged(area)
        let out = tmp().appendingPathComponent("staging")
        try FileManager.default.moveItem(at: area.stagingRoot, to: out)
        try FileManager.default.createSymbolicLink(at: area.stagingRoot, withDestinationURL: out)
        #expect(inbox.peekReady().isEmpty)
        #expect(throws: (any Error).self) { try StagingSession(area: area, target: target()).add(.text("x")) }
        #expect(names(out.appendingPathComponent("live/\(WS)")).count == 1)
    }

    @Test func symlinkedItemIsNeverReadCopiedOrDeletedThrough() throws {
        let area = ShareArea(shareGroupRoot: tmp()); let inbox = ShareInbox(area: area)
        let id = try staged(area)
        let (_, victim) = try outsideFile()
        let item = try area.stagingDir(realm: "live", ws: WS).appendingPathComponent(id).appendingPathComponent("item-1")
        try FileManager.default.removeItem(at: item)
        try FileManager.default.createSymbolicLink(at: item, withDestinationURL: victim)
        let job = inbox.peekReady()[0]
        #expect(inbox.text(of: job.manifest.items[0], in: job) == nil)
        inbox.complete(job)
        #expect(try String(contentsOf: victim, encoding: .utf8) == "victim")   // removal unlinks the link only
        // Quarantined copy of such a job cannot be redirected into a new job either.
        let id2 = try staged(area, target(WS2))
        let item2 = try area.stagingDir(realm: "live", ws: WS2).appendingPathComponent(id2).appendingPathComponent("item-1")
        try FileManager.default.removeItem(at: item2)
        try FileManager.default.createSymbolicLink(at: item2, withDestinationURL: victim)
        let q = inbox.claim(live: []).quarantined[0]
        #expect(throws: (any Error).self) { try inbox.redirect(q, to: LiveDestination(realm: "live", ws: WS, generation: 1)) }
        #expect(inbox.peekReady().isEmpty)
    }

    @Test func symlinkedReadyMarkerDoesNotMakeAJobReady() throws {
        let area = ShareArea(shareGroupRoot: tmp()); let inbox = ShareInbox(area: area)
        let id = try staged(area)
        let ready = try area.stagingDir(realm: "live", ws: WS).appendingPathComponent(id).appendingPathComponent("READY")
        try FileManager.default.removeItem(at: ready)
        let (_, victim) = try outsideFile()
        try FileManager.default.createSymbolicLink(at: ready, withDestinationURL: victim)
        #expect(inbox.peekReady().isEmpty)
    }

    @Test func pathStringsAreValidatedAsExactAsciiBytes() throws {
        let area = ShareArea(shareGroupRoot: tmp())
        let uuid = "11111111-1111-4111-8111-111111111111"
        let badIDs = ["%2e%2e", "%2E%2E%2Ftargets.json", "..", "../x", "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", uuid + "/", uuid + "\u{0}", " " + uuid,
                      "１１１１１１１１-1111-4111-8111-111111111111",           // fullwidth digits
                      "11111111-1111-4111-8111-11111111111\u{0131}",           // dotless i / look-alike
                      String(uuid.dropLast()) + "а"]                           // Cyrillic a
        for bad in badIDs {
            #expect(throws: ShareError.self) { try StagingSession(area: area, target: target(), jobID: bad) }
        }
        for bad in ["Live", "LIVE", "li\u{0435}", "liv%65", "a/../b", "live/", ".", "..", "live\u{0}", "ｌｉｖｅ"] {
            #expect(throws: ShareError.self) { try area.stagingDir(realm: bad, ws: WS) }
        }
        for bad in [String(repeating: "A", count: 32), String(repeating: "a", count: 31) + "%", String(repeating: "а", count: 32),
                    String(repeating: "a", count: 31) + "\u{0301}", "%2e%2e" + String(repeating: "a", count: 26), "../" + String(repeating: "a", count: 29)] {
            #expect(throws: ShareError.self) { try area.stagingDir(realm: "live", ws: bad) }
        }
        // On disk: directories with look-alike or uppercase names are ignored (and never deleted via other names).
        let inbox = ShareInbox(area: area)
        let s = try StagingSession(area: area, target: target()); try s.add(.text("x")); try s.commit(note: nil)
        let wsDir = try area.stagingDir(realm: "live", ws: WS)
        let real = wsDir.appendingPathComponent(s.id)
        let upper = wsDir.appendingPathComponent(s.id.uppercased())
        // On a case-insensitive volume the uppercase name aliases the real directory: it must not be accepted as a name.
        _ = try? FileManager.default.copyItem(at: real, to: wsDir.appendingPathComponent("%2e%2e"))
        try? FileManager.default.copyItem(at: real, to: wsDir.appendingPathComponent("Z" + s.id))
        #expect(inbox.peekReady().map(\.dir.lastPathComponent) == [s.id])
        _ = upper
    }

    @Test func manifestStringsAreComparedAsBytesNotCanonicalUnicode() throws {
        let area = ShareArea(shareGroupRoot: tmp()); let inbox = ShareInbox(area: area)
        let s = try StagingSession(area: area, target: target()); try s.add(.text("x")); let id = try s.commit(note: nil)
        let dir = try area.stagingDir(realm: "live", ws: WS).appendingPathComponent(id)
        var m = try JSONDecoder().decode(JobManifest.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        m.realm = "live\u{0301}"
        try JSONEncoder().encode(m).write(to: dir.appendingPathComponent("manifest.json"))
        #expect(inbox.peekReady().isEmpty)
    }
}

struct FinalShareFixTests {
    @Test func failedTombstoneSurvivesRestartAndPurgesBothLocations() throws {
        let area = ShareArea(shareGroupRoot: tmp())
        let inbox = ShareInbox(area: area)
        let q = try StagingSession(area: area, target: target())
        try q.add(.text("quarantined plaintext")); try q.commit(note: nil)
        _ = inbox.claim(live: [])
        let s = try StagingSession(area: area, target: target())
        try s.add(.text("staged plaintext")); try s.commit(note: nil)
        let record = TombstoneRecord(realm: "live", ws: WS, generation: 1)
        try inbox.recordRemoval(record)
        let tombstones = area.shareDir.appendingPathComponent("tombstones.json")
        try Data("{broken".utf8).write(to: tombstones)
        #expect(throws: (any Error).self) { try inbox.replayRemovals() }
        #expect(try inbox.pendingRemovals() == [record])
        try FileManager.default.removeItem(at: tombstones)
        let restarted = ShareInbox(area: area)
        try restarted.replayRemovals()
        #expect(try restarted.pendingRemovals().isEmpty)
        #expect(try area.coordination.records().contains(record))
        #expect(!ShareArea.exists(try area.stagingDir(realm: "live", ws: WS)))
        #expect(!ShareArea.exists(try area.quarantineDir(realm: "live", ws: WS)))
    }

    @Test func crashAfterJournalBeforeTombstoneIsReplayed() throws {
        let area = ShareArea(shareGroupRoot: tmp())
        let s = try StagingSession(area: area, target: target())
        try s.add(.text("partial plaintext"))
        let record = TombstoneRecord(realm: "live", ws: WS, generation: 1)
        try ShareInbox(area: area).recordRemoval(record)
        #expect(try area.coordination.records().isEmpty)
        try ShareInbox(area: area).replayRemovals()
        #expect(try area.coordination.records() == [record])
        #expect(try ShareInbox(area: area).pendingRemovals().isEmpty)
        #expect(!ShareArea.exists(try area.stagingDir(realm: "live", ws: WS)))
    }

    @Test @MainActor func oversizedTextProviderIsRefusedBeforeDecoding() async throws {
        let area = ShareArea(shareGroupRoot: tmp())
        let session = try StagingSession(area: area, target: target())
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
            completion(Data(repeating: 65, count: ShareLimits.maxTotalBytes + 1), nil)
            return nil
        }
        do {
            try await ProviderStager.stage(provider, into: session)
            Issue.record("oversized text was accepted")
        } catch { #expect(error as? ShareError == .tooLarge) }
        #expect(session.itemCount == 0)
        #expect(ShareInbox(area: area).peekReady().isEmpty)
    }

    @Test func canonicalFailsForMissingPathAndSymlinkLoop() throws {
        let root = tmp()
        #expect(throws: (any Error).self) { try ShareFS.canonical(root.appendingPathComponent("missing")) }
        let loop = root.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(at: loop, withDestinationURL: loop)
        #expect(throws: (any Error).self) { try ShareFS.canonical(loop) }
    }

    @Test func hardLinkedSourceAndRedirectAreRefused() throws {
        let area = ShareArea(shareGroupRoot: tmp())
        let source = sourceFile(32, in: tmp())
        try FileManager.default.linkItem(at: source, to: source.deletingLastPathComponent().appendingPathComponent("alias"))
        let s = try StagingSession(area: area, target: target())
        #expect(throws: (any Error).self) { try s.add(.providerCopy(source, name: "alias", type: nil)) }
        try s.add(.text("secret")); try s.commit(note: nil)
        let inbox = ShareInbox(area: area)
        let q = try #require(inbox.claim(live: []).quarantined.first)
        try FileManager.default.linkItem(at: q.dir.appendingPathComponent("item-1"), to: tmp().appendingPathComponent("alias"))
        #expect(throws: (any Error).self) { try inbox.redirect(q, to: LiveDestination(realm: "live", ws: WS2, generation: 1)) }
        #expect(inbox.quarantined().count == 1)
        #expect(inbox.peekReady().isEmpty)
    }
}
