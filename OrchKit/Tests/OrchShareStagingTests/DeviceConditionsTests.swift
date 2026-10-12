import Foundation
import Testing
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
