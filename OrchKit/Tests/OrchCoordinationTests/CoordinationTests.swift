import Foundation
import Testing
@testable import OrchCoordination

func coordTmp() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("orchcoord-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

struct CoordinationTests {
    @Test func ifNotRemovedAlwaysTakesTheLockEvenWithoutAnExistingDirectory() throws {
        let base = coordTmp().appendingPathComponent("missing", isDirectory: true)
        let ran = try TombstoneCoordination(directories: [base]).ifNotRemoved(realm: "live", ws: String(repeating: "a", count: 32), generation: 1) { true }
        #expect(ran == true)
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("tombstones.lock").path), "the body ran under a real lock")
    }

    @Test func removedWorkspaceNeverRunsTheBody() throws {
        let dir = coordTmp(), ws = String(repeating: "b", count: 32)
        let c = TombstoneCoordination(directories: [dir])
        try c.write(TombstoneRecord(realm: "live", ws: ws, generation: 2))
        var ran = false
        #expect(try c.ifNotRemoved(realm: "live", ws: ws, generation: 2) { ran = true } == nil)
        #expect(!ran)
        #expect(try c.ifNotRemoved(realm: "live", ws: ws, generation: 3) { 1 } == 1)
    }

    @Test func atomicWriteReplacesAndLeavesNoTemp() throws {
        let dir = coordTmp(), f = dir.appendingPathComponent("x.json")
        try CoordinationFiles.atomicWrite(Data("1".utf8), to: f, dir: dir)
        try CoordinationFiles.atomicWrite(Data("2".utf8), to: f, dir: dir, durable: false)
        #expect(try Data(contentsOf: f) == Data("2".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["x.json"])
    }

    @Test func nonBlockingFlockReturnsNilWhenHeld() throws {
        let path = coordTmp().appendingPathComponent("l").path
        let inner = try CoordinationFiles.withFlock(path) { () throws -> Bool? in
            // a second descriptor in the same process conflicts with the first on flock
            try CoordinationFiles.withFlock(path, blocking: false) { true }
        }
        #expect(inner == .some(nil))
    }
}
