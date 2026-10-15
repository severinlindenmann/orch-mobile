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
}
