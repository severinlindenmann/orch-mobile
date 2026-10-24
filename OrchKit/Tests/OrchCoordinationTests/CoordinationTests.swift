import Foundation
import Testing
@testable import OrchCoordination

func coordTmp() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("orchcoord-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

struct CoordinationTests {
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
