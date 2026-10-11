import Foundation
import OrchCoordination

extension ShareInbox {
    private var removalsURL: URL { area.shareDir.appendingPathComponent("pending-removals.json") }

    public func pendingRemovals() throws -> [TombstoneRecord] {
        let data: Data
        do { data = try area.readFile(removalsURL, cap: 256 * 1024) }
        catch ShareFS.ReadFailure.notFound { return [] }
        let records = try JSONDecoder().decode([TombstoneRecord].self, from: data)
        for r in records { try ShareArea.validate(realm: r.realm, ws: r.ws) }
        return records
    }

    /// App-only journal: fsync and atomic rename precede any removal from the destination index.
    public func recordRemoval(_ record: TombstoneRecord) throws {
        try area.ensureDirectory(area.shareDir)
        var records = try pendingRemovals()
        if !records.contains(record) { records.append(record) }
        try saveRemovals(records)
    }

    private func saveRemovals(_ records: [TombstoneRecord]) throws {
        try CoordinationFiles.atomicWrite(JSONEncoder().encode(records), to: removalsURL, dir: area.shareDir)
    }

    /// Run before publishing/claiming on launch. Keep the record on any failure, including plaintext deletion.
    public func replayRemovals() throws {
        let records = try pendingRemovals()
        var remaining = records
        for record in records {
            try area.coordination.write(record)
            let dirs = [try area.stagingDir(realm: record.realm, ws: record.ws),
                        try area.quarantineDir(realm: record.realm, ws: record.ws)]
            var purged = true
            for dir in dirs { if !area.safeRemove(dir) { purged = false } }
            guard purged else { throw ShareError.io("pending removal purge failed") }
            remaining.removeAll { $0 == record }
            try saveRemovals(remaining)
        }
    }
}
