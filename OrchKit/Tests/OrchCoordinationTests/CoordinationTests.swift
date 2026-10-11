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

struct TombstoneFileSafetyTests {
    @Test func corruptBytesArePreservedWhenRepublishingAnEmptySet() throws {
        let dir = coordTmp(), file = dir.appendingPathComponent("tombstones.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data("broken json".utf8)
        try bytes.write(to: file)
        let c = TombstoneCoordination(directories: [dir])
        try c.republish(complete: [])
        #expect(try c.records().isEmpty)
        let aside = try #require(FileManager.default.contentsOfDirectory(atPath: dir.path).first { $0.hasPrefix("tombstones.json.corrupt-") })
        #expect(try Data(contentsOf: dir.appendingPathComponent(aside)) == bytes)
    }

    @Test(arguments: ["tombstones.json", "tombstones.lock"])
    func plantedSymlinkIsRefused(name: String) throws {
        let dir = coordTmp(), outside = coordTmp().appendingPathComponent("victim")
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: outside.deletingLastPathComponent()) }
        let bytes = Data("[]".utf8)
        try bytes.write(to: outside)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent(name), withDestinationURL: outside)
        let c = TombstoneCoordination(directories: [dir])
        let record = TombstoneRecord(realm: "live", ws: "workspace", generation: 1)
        #expect(c.removalStatus(realm: "live", ws: record.ws, generation: 1) == .unknown)
        #expect(throws: (any Error).self) { try c.records() }
        #expect(throws: (any Error).self) { try c.write(record) }
        #expect(throws: (any Error).self) { try c.republish(complete: [record]) }
        var ran = false
        _ = try? c.ifNotRemoved(realm: "live", ws: record.ws, generation: 1) { ran = true }
        #expect(!ran)
        #expect(try Data(contentsOf: outside) == bytes)
    }

    @Test(arguments: ["tombstones.json", "tombstones.lock"], [false, true])
    func nonregularAndOversizedEntriesAreRefused(name: String, oversized: Bool) throws {
        let dir = coordTmp(), file = dir.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: dir) }
        if oversized { try Data(repeating: 0, count: TombstoneFS.cap + 1).write(to: file) }
        else { #expect(mkfifo(file.path, 0o600) == 0) }
        let c = TombstoneCoordination(directories: [dir])
        #expect(throws: (any Error).self) { try c.records() }
        #expect(c.removalStatus(realm: "live", ws: "workspace", generation: 1) == .unknown)
    }

    @Test func directorySymlinkIsRefused() throws {
        let base = coordTmp(), outside = coordTmp(), link = base.appendingPathComponent("coordination")
        defer { try? FileManager.default.removeItem(at: base); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let c = TombstoneCoordination(directories: [link])
        #expect(throws: (any Error).self) { try c.write(TombstoneRecord(realm: "live", ws: "workspace", generation: 1)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
}

struct FlockFileSafetyTests {
    @Test func symlinkedParentIsRefused() throws {
        let root = coordTmp()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real", isDirectory: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        #expect(throws: CoordinationFiles.FileError.self) {
            try CoordinationFiles.withFlock(alias.appendingPathComponent("lock").path) { Issue.record("unsafe body ran") }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: real.path).isEmpty)
    }

    @Test(arguments: ["hardlink", "symlink", "fifo"])
    func unsafeLockIsRefused(kind: String) throws {
        let root = coordTmp()
        defer { try? FileManager.default.removeItem(at: root) }
        let victim = root.appendingPathComponent("victim")
        let lock = root.appendingPathComponent("lock")
        let bytes = Data("keep".utf8)
        try bytes.write(to: victim)
        switch kind {
        case "hardlink": try FileManager.default.linkItem(at: victim, to: lock)
        case "symlink": try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: victim)
        default: #expect(mkfifo(lock.path, 0o600) == 0)
        }
        #expect(throws: CoordinationFiles.FileError.self) {
            try CoordinationFiles.withFlock(lock.path) { Issue.record("unsafe body ran") }
        }
        #expect(try Data(contentsOf: victim) == bytes)
    }
}
