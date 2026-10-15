import Foundation
import Testing
import OrchCoordination
@testable import OrchShareStaging

/// On a device `containerURL(forSecurityApplicationGroupIdentifier:)` returns `/private/var/mobile/Containers/Shared/AppGroup/…`.
/// `URL.standardizedFileURL` drops a leading `/private` only when the path EXISTS, so comparing an existing directory with a
/// not-yet-existing file below it used to fail ("outside share dir"): the first `publish` threw (swallowed by the app) and the
/// extension's load reported "index: unreadable". Simulator and macOS fixture roots have no `/private` prefix, so they never hit it.
func privateRoot() -> URL {
    let u = URL(fileURLWithPath: "/private/tmp/orchshare-dev-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

struct DeviceConditionsTests {
    @Test func privatePrefixedContainerPublishesAndLoads() throws {
        let area = ShareArea(shareGroupRoot: privateRoot())
        #expect(area.shareDir.path.hasPrefix("/private/"))
        try ShareTargetIndex.publish([target(), target(WS2)], to: area)
        let loaded = try ShareTargetIndex.load(from: area)
        #expect(loaded.map(\.ws) == [WS, WS2])
    }

    @Test func privatePrefixedContainerWithExistingShareDirPublishes() throws {
        let root = privateRoot()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("share"), withIntermediateDirectories: true)
        let area = ShareArea(shareGroupRoot: root)
        try ShareTargetIndex.publish([target()], to: area)
        #expect(try ShareTargetIndex.load(from: area).count == 1)
    }

    @Test func privatePrefixedContainerMissingIndexIsNoWorkspaces() throws {
        let root = privateRoot()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("share"), withIntermediateDirectories: true)
        #expect(throws: ShareError.noWorkspaces) { try ShareTargetIndex.load(from: ShareArea(shareGroupRoot: root)) }
    }

    @Test func privatePrefixedContainerStagesAndClaims() throws {
        let area = ShareArea(shareGroupRoot: privateRoot())
        let s = try StagingSession(area: area, target: target())
        try s.add(.text("hello"))
        _ = try s.commit(note: nil)
        #expect(ShareInbox(area: area).peekReady().count == 1)
    }

    @Test func unprefixedUrlForPrivateContainerIsInside() throws {
        let root = privateRoot()
        let area = ShareArea(shareGroupRoot: root)
        let bare = URL(fileURLWithPath: String(area.targetsURL.path.dropFirst("/private".count)))
        #expect(area.components(of: bare) == ["targets.json"])
    }
}

/// Each device-side failure the extension can meet has its own path-free reason (it used to collapse into "unreadable").
struct IndexFailureTests {
    func published(_ root: URL = privateRoot()) throws -> ShareArea {
        let area = ShareArea(shareGroupRoot: root)
        try ShareTargetIndex.publish([target()], to: area)
        return area
    }

    @Test(.enabled(if: geteuid() != 0, "root ignores chmod")) func protectedOrDeniedIndexReportsErrno() throws {
        let area = try published()
        // Data protection or a sandbox denial surfaces as EACCES/EPERM from open(2); chmod 000 gives the same errno path.
        #expect(chmod(area.targetsURL.path, 0) == 0)
        defer { chmod(area.targetsURL.path, 0o600) }
        #expect(throws: ShareError.index(.io(EACCES))) { try ShareTargetIndex.load(from: area) }
        #expect(ShareIndexFailure.io(EACCES).code == "io 13 EACCES")
    }

    @Test func schemaMismatchNamesTheKeyNotTheValue() throws {
        let area = try published()
        let json = #"{"version":1,"targets":[{"realm":"live","ws":"\#(WS)","name":"Secret Name","generation":1}]}"#
        try Data(json.utf8).write(to: area.targetsURL)
        #expect(throws: ShareError.index(.decode("keyNotFound targets.0.hue"))) { try ShareTargetIndex.load(from: area) }
    }

    @Test func futureVersionIsSpecific() throws {
        let area = try published()
        try Data(#"{"version":2,"targets":[]}"#.utf8).write(to: area.targetsURL)
        #expect(throws: ShareError.index(.version(2))) { try ShareTargetIndex.load(from: area) }
    }

    @Test func invalidEntryIsSpecific() throws {
        let area = try published()
        let json = #"{"version":1,"targets":[{"realm":"live","ws":"zz","name":"n","hue":0,"generation":1}]}"#
        try Data(json.utf8).write(to: area.targetsURL)
        #expect(throws: ShareError.index(.invalidEntry)) { try ShareTargetIndex.load(from: area) }
    }

    @Test func linkedIndexIsRefusedWithELOOP() throws {
        let area = try published()
        let elsewhere = privateRoot().appendingPathComponent("t.json")
        try Data("{}".utf8).write(to: elsewhere)
        try FileManager.default.removeItem(at: area.targetsURL)
        try FileManager.default.createSymbolicLink(at: area.targetsURL, withDestinationURL: elsewhere)
        #expect(throws: ShareError.index(.io(ELOOP))) { try ShareTargetIndex.load(from: area) }
    }

    @Test func unusableLockFileIsReportedNotHiddenAsNoWorkspaces() throws {
        let area = try published()
        // The extension may not be able to create/open the lock (sandbox): a directory in its place makes open(2) fail.
        let lock = area.shareDir.appendingPathComponent("tombstones.lock")
        try? FileManager.default.removeItem(at: lock)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        #expect(throws: ShareError.index(.tombstones("lock \(EISDIR) EISDIR"))) { try ShareTargetIndex.load(from: area) }
    }

    @Test func corruptTombstonesAreReported() throws {
        let area = try published()
        try Data("garbage".utf8).write(to: area.shareDir.appendingPathComponent("tombstones.json"))
        #expect(throws: ShareError.index(.tombstones("corrupt"))) { try ShareTargetIndex.load(from: area) }
    }

    @Test func publishFailureIsRecordedForDiagnostics() throws {
        let area = try published()
        let first = ShareTargetIndex.PublishStatus.read(from: area)
        #expect(first?.result == "ok")
        #expect(first?.targets == 1)
        #expect(throws: ShareError.self) {
            try ShareTargetIndex.publish([ShareTarget(realm: "live", ws: "bad", name: "n", hue: 0, generation: 1)], to: area)
        }
        let second = ShareTargetIndex.PublishStatus.read(from: area)
        #expect(second?.result == "io: invalid workspace")
    }
}

struct DiagnosticsTests {
    func value(_ lines: [ShareDiagnostics.Line], _ label: String) -> String? { lines.first { $0.label == label }?.value }

    @Test func nilContainerIsReported() {
        let lines = ShareDiagnostics.collect(groupID: "group.io.severin.orch.share", root: nil)
        #expect(value(lines, "Container")?.hasPrefix("not resolvable") == true)
        #expect(lines.count == 2)
    }

    @Test func healthyDeviceShapedContainer() throws {
        let root = privateRoot()
        let area = ShareArea(shareGroupRoot: root)
        try ShareTargetIndex.publish([ShareTarget(realm: "demo", ws: WS, name: "Secret Name", hue: 1, generation: 1)], to: area)
        let lines = ShareDiagnostics.collect(groupID: "group.io.severin.orch.share", root: root)
        #expect(value(lines, "Container path form") == "/private/… (device)")
        #expect(value(lines, "Path check") == "ok")
        #expect(value(lines, "Index decode") == "ok, version 1, 1 targets (1 Demo)")
        #expect(value(lines, "Offered") == "1 destinations")
        #expect(value(lines, "Tombstone lock")?.hasPrefix("acquired") == true)
        #expect(value(lines, "Last app publish")?.hasSuffix(": ok, 1 targets") == true)
        // Never a path, a workspace id or a name.
        let all = lines.map { "\($0.label) \($0.value)" }.joined(separator: "\n")
        #expect(!all.contains("Secret"))
        #expect(!all.contains(root.lastPathComponent))
        #expect(!all.contains(WS))
    }

    @Test func emptyContainerSkipsTheLockProbe() {
        let root = privateRoot()
        let lines = ShareDiagnostics.collect(groupID: "g", root: root)
        #expect(value(lines, "Share folder") == "missing")
        #expect(value(lines, "Index decode") == "none")
        #expect(value(lines, "Tombstone lock") == "skipped (no share folder)")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("share").path))
    }

    @Test(.enabled(if: geteuid() != 0, "root ignores chmod")) func deniedIndexShowsErrnoInDiagnostics() throws {
        let root = privateRoot()
        let area = ShareArea(shareGroupRoot: root)
        try ShareTargetIndex.publish([target()], to: area)
        #expect(chmod(area.targetsURL.path, 0) == 0)
        defer { chmod(area.targetsURL.path, 0o600) }
        let lines = ShareDiagnostics.collect(groupID: "g", root: root)
        #expect(value(lines, "Index decode") == "io 13 EACCES")
        #expect(value(lines, "Offered") == "io 13 EACCES")
    }
}

/// Fix round (PR #62 review): untrusted status file, fd-relative diagnostics, stale index, fixed staging codes.
struct ReviewRoundTests {
    func value(_ lines: [ShareDiagnostics.Line], _ label: String) -> String? { lines.first { $0.label == label }?.value }

    @Test func forgedStatusFileIsSanitised() throws {
        let root = privateRoot()
        let area = ShareArea(shareGroupRoot: root)
        try ShareTargetIndex.publish([target()], to: area)
        // PoC: newline + fake line, RLO, NUL, absurd year, negative count.
        let forged = #"{"at":1e15,"result":"ok\nOffered: 99 destinations\u202e\u0000","targets":-5}"#
        try Data(forged.utf8).write(to: area.shareDir.appendingPathComponent("index-status.json"))
        let now = Date()
        let s = try #require(ShareTargetIndex.PublishStatus.read(from: area, now: now))
        #expect(s.result == "invalid")
        #expect(s.targets == 0)
        #expect(s.at <= now.timeIntervalSince1970 + 86_400)
        let lines = ShareDiagnostics.collect(groupID: "g", root: root)
        let last = try #require(value(lines, "Last app publish"))
        #expect(!last.contains("\n"))
        #expect(!last.contains("Offered"))
        #expect(last.hasSuffix(": invalid, 0 targets"))
    }

    @Test func oversizedOrEarlyStatusIsClamped() throws {
        let area = ShareArea(shareGroupRoot: privateRoot())
        try ShareTargetIndex.publish([], to: area)
        let long = String(repeating: "a", count: 121)
        try Data(#"{"at":-3,"result":"\#(long)","targets":99999999}"#.utf8).write(to: area.shareDir.appendingPathComponent("index-status.json"))
        let s = try #require(ShareTargetIndex.PublishStatus.read(from: area))
        #expect(s.result == "invalid")
        #expect(s.targets == 10_000)
        #expect(s.at == 1_577_836_800)
    }

    @Test func swappedShareLinkIsRefusedNotFollowed() throws {
        let root = privateRoot()
        let elsewhere = privateRoot()
        try ShareTargetIndex.publish([target()], to: ShareArea(shareGroupRoot: elsewhere))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("share"), withDestinationURL: elsewhere.appendingPathComponent("share"))
        let lines = ShareDiagnostics.collect(groupID: "g", root: root)
        #expect(value(lines, "Share folder") == "refused (link or not a folder)")
        #expect(value(lines, "Index file") == "refused")
        #expect(value(lines, "Index decode") == "io \(ENOTDIR) ENOTDIR")
        #expect(value(lines, "Tombstone lock") == "skipped (no share folder)")
    }

    @Test func swappedIndexLinkIsRefusedInDiagnostics() throws {
        let root = privateRoot()
        let area = ShareArea(shareGroupRoot: root)
        try ShareTargetIndex.publish([target()], to: area)
        let other = privateRoot().appendingPathComponent("other.json")
        try Data(repeating: 0x20, count: 777).write(to: other)
        try FileManager.default.removeItem(at: area.targetsURL)
        try FileManager.default.createSymbolicLink(at: area.targetsURL, withDestinationURL: other)
        let index = try #require(value(ShareDiagnostics.collect(groupID: "g", root: root), "Index file"))
        #expect(index == "refused (link)")
        #expect(!index.contains("777"))
    }

    @Test func skippedPublishMarksIndexStale() throws {
        let area = ShareArea(shareGroupRoot: privateRoot())
        try ShareTargetIndex.publish([target(), target(WS2)], to: area)
        ShareTargetIndex.recordPublishSkipped("removal replay: tombstones corrupt", in: area)
        // The extension offers nothing from a stale index ...
        #expect(throws: ShareError.index(.stale("removal replay: tombstones corrupt"))) { try ShareTargetIndex.load(from: area) }
        // ... but the app still sees every persisted destination to retire.
        #expect(try ShareTargetIndex.persisted(from: area).count == 2)
        let decode = try #require(value(ShareDiagnostics.collect(groupID: "g", root: area.shareGroupRoot), "Index decode"))
        #expect(decode.hasSuffix("stale: removal replay: tombstones corrupt"))
        // A successful publish clears the mark.
        try ShareTargetIndex.publish([target()], to: area)
        #expect(try ShareTargetIndex.load(from: area).count == 1)
    }

    @Test func skippedPublishWithoutIndexOffersNothing() throws {
        let area = ShareArea(shareGroupRoot: privateRoot())
        ShareTargetIndex.recordPublishSkipped("tombstones: corrupt", in: area)
        #expect(throws: ShareError.noWorkspaces) { try ShareTargetIndex.load(from: area) }
        #expect(ShareTargetIndex.PublishStatus.read(from: area)?.result == "skipped: tombstones: corrupt")
    }

    @Test func failedStaleMarkIsRecordedInTheStatus() throws {
        let area = ShareArea(shareGroupRoot: privateRoot())
        try ShareTargetIndex.publish([target()], to: area)
        // An unreadable index (here a link) cannot be marked stale: the status must say so, not just "skipped".
        let other = area.shareGroupRoot.appendingPathComponent("other.json")
        try Data("{}".utf8).write(to: other)
        try FileManager.default.removeItem(at: area.targetsURL)
        try FileManager.default.createSymbolicLink(at: area.targetsURL, withDestinationURL: other)
        ShareTargetIndex.recordPublishSkipped("tombstones: corrupt", in: area)
        let result = try #require(ShareTargetIndex.PublishStatus.read(from: area)?.result)
        #expect(result == "skipped: tombstones: corrupt mark failed: io 62 ELOOP")
    }

    @Test func stagingErrorsNeverCarryPaths() {
        let cocoa = CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: "/private/var/mobile/secret"])
        #expect(StagingSession.fixedCode(cocoa) == "staging failed")
        #expect(StagingSession.fixedCode(TombstoneError.io("open: 2")) == "tombstones io")
        #expect(ShareError.io("/private/var/x").code == "io: invalid")
    }
}
