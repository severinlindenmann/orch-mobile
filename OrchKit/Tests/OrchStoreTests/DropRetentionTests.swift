import Foundation
import Testing
@testable import OrchStore

struct DropRetentionTests {
    @Test(arguments: [7, 9]) func migrationPurgesUntrackedLegacyPlaintext(schema: Int) async throws {
        let layout = try makeLayout(tempDir()), index = try await WorkspaceIndex(layout: layout)
        try layout.prepareWorkspace(A)
        let old = try SQLiteDatabase(url: layout.wsDatabaseURL(A))
        try await old.migrate(Array(WorkspaceContainer.migrations.prefix(schema)))
        try await old.execute("INSERT INTO drop_heads(object,version,hash) VALUES(?,1,?)", [.text(A), .blob(Data([1]))])
        if schema >= 8 {
            try await old.execute("UPDATE drop_heads SET file_version=1")
        }
        await old.close()
        let file = try layout.filesDir(A).appendingPathComponent("\(A)-1")
        try Data("legacy plaintext".utf8).write(to: file)
        let container = try await WorkspaceContainer(index: index, ws: A, generation: 1)
        try await container.purgeExpiredDownloads(nowMs: 0)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try await container.database().query("SELECT version FROM drop_heads").first?.int("version") == 1)
    }

    @Test func perObjectPurgeRemovesOnlyThatObjectsFiles() async throws {
        let layout = try makeLayout(tempDir()), index = try await WorkspaceIndex(layout: layout)
        try layout.prepareWorkspace(A)
        let container = try await WorkspaceContainer(index: index, ws: A, generation: 1)
        let dir = try layout.filesDir(A)
        for id in [A, B] {
            try await container.acceptDropChain(object: id, chain: [Data([1])])
            _ = try await container.writeDropVerified(Data("plain-\(id)".utf8), object: id, version: 1, expiresMs: nil, now: { 1_000 })
        }
        try await container.purgeDownloads(objects: [])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 2)
        try await container.purgeDownloads(objects: [A, String(repeating: "c", count: 32)])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(A)-1").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(B)-1").path))
        let heads = try await container.database().query("SELECT object,version,file_version FROM drop_heads ORDER BY object")
        #expect(heads.count == 2 && heads[0].int("file_version") == nil && heads[1].int("file_version") == 1)
        #expect(heads.allSatisfy { $0.int("version") == 1 })
        await #expect(throws: (any Error).self) { try await container.purgeDownloads(objects: ["../x"]) }
    }

    @Test func keepingPurgeRemovesEveryObjectNotKeptAndUntrackedFiles() async throws {
        let layout = try makeLayout(tempDir()), index = try await WorkspaceIndex(layout: layout)
        try layout.prepareWorkspace(A)
        let container = try await WorkspaceContainer(index: index, ws: A, generation: 1)
        let dir = try layout.filesDir(A), C = String(repeating: "c", count: 32)
        for id in [A, B, C] {
            try await container.acceptDropChain(object: id, chain: [Data([1])])
            _ = try await container.writeDropVerified(Data(id.utf8), object: id, version: 1, expiresMs: nil, now: { 1_000 })
        }
        try Data("x".utf8).write(to: dir.appendingPathComponent("\(String(repeating: "d", count: 32))-1"))
        try await container.purgeDownloads(keeping: [A, B])
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(names == ["\(A)-1", "\(B)-1"])
        let heads = try await container.database().query("SELECT object,file_version FROM drop_heads ORDER BY object")
        #expect(heads.count == 3 && heads[2].int("file_version") == nil && heads[0].int("file_version") == 1)
    }
}
