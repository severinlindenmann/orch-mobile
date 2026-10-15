import Foundation
import Testing
@testable import OrchStore

@Suite struct WipeBeginTests {
    @Test func beginMakesTheIntentDurableWithoutWipingAndARelaunchFinishesIt() async throws {
        let layout = try makeLayout(tempDir())
        let index = try await WorkspaceIndex(layout: layout)
        try await index.addWorkspace(ws: A, generation: 1)
        let c = try await WorkspaceContainer(index: index, ws: A, generation: 1)
        _ = try await c.recordRequestId("keep")
        try await LocalWipe(index: index).begin(ws: A, generation: 1)
        let t = try await index.tombstones()
        #expect(t.count == 1 && t[0].phase == 1)
        #expect(FileManager.default.fileExists(atPath: try layout.wsDir(A).path), "nothing is wiped yet")
        // a restart finds the tombstone and finishes the wipe; begin again is idempotent
        try await LocalWipe(index: index).begin(ws: A, generation: 1)
        let resumed = try await LocalWipe(index: index).resumePendingWipes()
        #expect(resumed == [A])
        #expect(!FileManager.default.fileExists(atPath: try layout.wsDir(A).path))
        #expect(try await index.tombstones().allSatisfy { $0.phase >= LocalWipe.donePhase })
    }
}
