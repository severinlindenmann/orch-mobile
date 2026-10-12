import CryptoKit
import Foundation
import OrchProtocol
import OrchPushFixtures
import OrchStore
import Testing
@testable import OrchPush

func tmp() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("orchpush-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

struct StaticSource: PushMaterialSource {
    var items: [ID16: PushMaterial]
    var fail: PushMaterialError?
    func loadAll(realm: String) throws -> [ID16: PushMaterial] { if let fail { throw fail }; return items }
}

func material(_ w: PushFixtures.Workspace, generation: Int64 = 1) -> PushMaterial {
    try! PushMaterial.decode(PushFixtures.materialJSON(w, generation: generation))
}

let nowMs: Int64 = 1_800_000_000_000
func handler(dir: URL, _ items: [ID16: PushMaterial], at ms: Int64 = nowMs, fail: PushMaterialError? = nil) -> PushHandler {
    PushHandler(material: StaticSource(items: items, fail: fail), pushDir: dir, now: { Date(timeIntervalSince1970: Double(ms) / 1000) })
}
func outerString(_ f: PushFixtures.Fixture) -> String {
    ((try! JSONSerialization.jsonObject(with: f.apns)) as! [String: Any])["o"] as! String
}

struct ReplayPerWorkspaceTests {
    let a = PushFixtures.workspaceA, b = PushFixtures.workspaceB

    func seal(_ w: PushFixtures.Workspace, id: String, ts: Int64) -> Data {
        Data(PushFixtures.seal(w, PushFixtures.payload(kind: "question", id: id, label: "x", tsMs: ts)).utf8)
    }
    var keys: PushProcessor.Keyring { [a.id: material(a).keys, b.id: material(b).keys] }

    @Test func testPushReplayWatermarkIsPerWorkspace() {
        // A shows a push at the far edge of the skew window; B holds an older (but fresh) push and an old entry.
        var r = PushProcessor.ReplayState()
        r = PushProcessor.process(outer: seal(b, id: "old", ts: nowMs - 20 * 3600_000), keys: keys, replay: r, nowMs: nowMs).replay
        let high = PushProcessor.process(outer: seal(a, id: "hi", ts: nowMs + 299_000), keys: keys, replay: r, nowMs: nowMs)
        guard case .show = high.result else { Issue.record("A not shown"); return }
        r = high.replay
        #expect(r.maxShownTs(for: a.id) == nowMs + 299_000)
        #expect(r.maxShownTs(for: b.id) == nowMs - 20 * 3600_000)
        // A's high mark neither suppresses B's next push nor prunes B's entries, even 30 h of A-time later.
        let later = nowMs + 30 * 3600_000
        let bNext = PushProcessor.process(outer: seal(b, id: "next", ts: later - 1000), keys: keys, replay: r, nowMs: later)
        guard case .show = bNext.result else { Issue.record("B suppressed: \(bNext.result)"); return }
        let aLate = PushProcessor.process(outer: seal(a, id: "hi2", ts: later), keys: keys, replay: r, nowMs: later)
        #expect(aLate.replay.last(workspace: b.id, id: "old") == nowMs - 20 * 3600_000, "B entry pruned by A's push")
        // The proof: 23 h 58 min old is below A's floor (A mark - 24 h) but above B's, so only B may still show it.
        let edge = nowMs - (23 * 3600 + 58 * 60) * 1000
        guard case .show = PushProcessor.process(outer: seal(b, id: "edge", ts: edge), keys: keys, replay: r, nowMs: nowMs).result else { Issue.record("B floored by A"); return }
        #expect(PushProcessor.process(outer: seal(a, id: "edge", ts: edge), keys: keys, replay: r, nowMs: nowMs).result == .drop(.stale))
        // And a workspace the state has never seen starts with no history.
        #expect(r.maxShownTs(for: ID16.random()) == Int64.min)
    }

    @Test func testPushReplayMigrationAndWorkspaceWipe() async throws {
        // Legacy global table: A's retained entries, B's retained entry, C nothing. The legacy global mark is not an input.
        let legacy: [PushProcessor.ReplayState.LegacyEntry] = [
            .init(workspace: a.id, id: "q1", tsMs: nowMs - 1000), .init(workspace: a.id, id: "q0", tsMs: nowMs - 2000),
            .init(workspace: b.id, id: "q9", tsMs: nowMs - 5 * 3600_000),
        ]
        let m = PushProcessor.ReplayState.migrating(legacy: legacy)
        #expect(m.maxShownTs(for: a.id) == nowMs - 1000)
        #expect(m.maxShownTs(for: b.id) == nowMs - 5 * 3600_000, "B must not inherit A's mark")
        #expect(m.maxShownTs(for: PushFixtures.unknown.id) == Int64.min)
        #expect(m.last(workspace: a.id, id: "q0") == nowMs - 2000)
        // Entries beyond 24 h of their own workspace's mark are pruned at migration.
        let old = PushProcessor.ReplayState.migrating(legacy: [.init(workspace: a.id, id: "a", tsMs: nowMs - 30 * 3600_000), .init(workspace: a.id, id: "b", tsMs: nowMs)])
        #expect(old.last(workspace: a.id, id: "a") == nil && old.last(workspace: a.id, id: "b") == nowMs)

        // Persisted state is cleared with the workspace: StoreLayout.pushStateDir is the directory LocalWipe phase 3 removes.
        let base = tmp()
        let layout = try StoreLayout(appRoot: base.appendingPathComponent("app"), pushGroupRoot: base.appendingPathComponent("push"),
                                     shareGroupRoot: base.appendingPathComponent("share"), realm: "live")
        let store = ReplayStore(pushDir: layout.pushDir, realm: "live")
        #expect(store.stateDir(workspace: a.id).standardizedFileURL == (try layout.pushStateDir(a.id.hex)).standardizedFileURL)
        try store.transact(workspace: a.id, generation: 1, nowMs: nowMs) { _ in ((), PushProcessor.WorkspaceReplay().recordingForTest("q", 5)) }
        try store.transact(workspace: b.id, generation: 1, nowMs: nowMs) { _ in ((), PushProcessor.WorkspaceReplay().recordingForTest("q", 5)) }
        let ws = a.id.hex
        // Awaited, never a semaphore: blocking a cooperative-pool thread on work that needs the pool deadlocked CI's 3-core runner.
        let idx = try await WorkspaceIndex(layout: layout)
        try await idx.addWorkspace(ws: ws, generation: 1)
        try await LocalWipe(index: idx).wipe(ws: ws, generation: 1)
        #expect(try store.load(workspace: a.id, generation: 1) == nil, "wipe must remove A's replay state")
        #expect(try store.load(workspace: b.id, generation: 1) != nil, "B's state survives A's wipe")
    }
}

extension ReplayStore {
    func peek(_ ws: ID16, _ generation: Int64) throws -> PushProcessor.WorkspaceReplay {
        try transact(workspace: ws, generation: generation, nowMs: nowMs) { ($0, nil as PushProcessor.WorkspaceReplay?) }
    }
}

extension PushProcessor.WorkspaceReplay {
    func recordingForTest(_ id: String, _ ts: Int64) -> Self { .init(lastShown: [PushProcessor.WorkspaceReplay.key(id): ts], maxShownTs: ts) }
}

struct ReplayStoreTests {
    let a = PushFixtures.workspaceA

    @Test func roundTripPerRealmWorkspaceGeneration() throws {
        let dir = tmp()
        let s = ReplayStore(pushDir: dir, realm: "live")
        let st = PushProcessor.WorkspaceReplay(lastShown: [PushProcessor.WorkspaceReplay.key("q1"): 10, PushProcessor.WorkspaceReplay.key("\u{e9}"): 7], maxShownTs: 10, notBeforeTs: 3)
        #expect(try s.peek(a.id, 3).isEmpty)
        try s.transact(workspace: a.id, generation: 3, nowMs: nowMs) { _ in ((), st) }
        #expect(try s.load(workspace: a.id, generation: 3) == st)
        #expect(try s.load(workspace: a.id, generation: 4) == nil)
        #expect(try ReplayStore(pushDir: dir, realm: "demo").load(workspace: a.id, generation: 3) == nil, "realm separated")
        // No temp or lock files in the purgeable state directory.
        let names = try FileManager.default.contentsOfDirectory(atPath: s.stateDir(workspace: a.id).path).sorted()
        #expect(names == ["replay.3.json"])
    }

    @Test func newerGenerationReplacesOlderAndStaleMaterialIsRefused() throws {
        let s = ReplayStore(pushDir: tmp(), realm: "live")
        let st = PushProcessor.WorkspaceReplay(lastShown: [PushProcessor.WorkspaceReplay.key("q"): 1], maxShownTs: 1)
        try s.transact(workspace: a.id, generation: 1, nowMs: nowMs) { _ in ((), st) }
        #expect(try s.peek(a.id, 2).notBeforeTs == 1, "a rejoin starts above the old generation's high-water mark")
        try s.transact(workspace: a.id, generation: 2, nowMs: nowMs) { _ in ((), st) }
        #expect(try s.load(workspace: a.id, generation: 1) == nil)
        #expect(throws: ReplayStoreError.newerGeneration) { try s.transact(workspace: a.id, generation: 1, nowMs: nowMs) { ($0, nil as PushProcessor.WorkspaceReplay?) } }
    }

    @Test func corruptStateIsRecoveredInsideTheTransactionAboveTheRecoveryTime() throws {
        let s = ReplayStore(pushDir: tmp(), realm: "live")
        try s.transact(workspace: a.id, generation: 1, nowMs: nowMs) { _ in ((), PushProcessor.WorkspaceReplay().recordingForTest("q", 1)) }
        let f = s.fileURL(workspace: a.id, generation: 1)
        try Data("not json".utf8).write(to: f)
        // a snapshot never mutates: it reports corruption and leaves the file alone
        #expect(throws: ReplayStoreError.corrupt) { _ = try s.load(workspace: a.id, generation: 1) }
        #expect(try Data(contentsOf: f) == Data("not json".utf8))
        // recovery happens only in the transaction: moved aside, fresh state above `now`, written at once
        let seen = try s.transact(workspace: a.id, generation: 1, nowMs: nowMs) { ($0, nil as PushProcessor.WorkspaceReplay?) }
        #expect(seen.notBeforeTs == nowMs && seen.lastShown.isEmpty)
        #expect(FileManager.default.fileExists(atPath: f.appendingPathExtension("corrupt").path))
        #expect(try s.load(workspace: a.id, generation: 1)?.notBeforeTs == nowMs)
        // a file copied from another workspace does not parse as this one's
        let bid = PushFixtures.workspaceB.id
        try FileManager.default.createDirectory(at: s.stateDir(workspace: bid), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: f, to: s.fileURL(workspace: bid, generation: 1))
        #expect(throws: ReplayStoreError.corrupt) { _ = try s.load(workspace: bid, generation: 1) }
    }

    @Test func crashBeforeRenameLeavesOldStateIntact() throws {
        let s = ReplayStore(pushDir: tmp(), realm: "live")
        let old = PushProcessor.WorkspaceReplay().recordingForTest("old", 1)
        try s.transact(workspace: a.id, generation: 1, nowMs: nowMs) { _ in ((), old) }
        // A body that throws after computing a next state persists nothing.
        struct Boom: Error {}
        #expect(throws: Boom.self) { try s.transact(workspace: a.id, generation: 1, nowMs: nowMs) { (_: PushProcessor.WorkspaceReplay) -> (Void, PushProcessor.WorkspaceReplay?) in throw Boom() } }
        // A stray half-written temp file from a crashed writer is ignored by readers.
        try Data("{".utf8).write(to: s.stateDir(workspace: a.id).appendingPathComponent(".tmp-crashed"))
        #expect(try s.load(workspace: a.id, generation: 1) == old)
    }
}

struct PushHandlerTests {
    let a = PushFixtures.workspaceA, b = PushFixtures.workspaceB

    func run(_ name: String, in h: PushHandler, fixtures: [PushFixtures.Fixture]) -> PushHandler.Result {
        h.handle(o: outerString(fixtures.first { $0.name == name }!))
    }

    @Test func fixtureSequenceMatchesExpectations() {
        let dir = tmp()
        let h = handler(dir: dir, [a.id: material(a)])
        let seq = PushFixtures.sequence(nowMs: nowMs)
        for f in seq {
            let r = h.handle(o: outerString(f))
            #expect(r.outcome.rawValue == f.expectedOutcome, "\(f.name)")
            #expect(r.presentation.body == (f.expectedBody ?? PushPresentation.genericBody), "\(f.name)")
            if f.expectedBody == nil { #expect(r.presentation == .generic, "\(f.name): drops show only app-authored text") }
        }
        #expect(NSEMarker.read(pushDir: dir)?.count == seq.count)
    }

    @Test func eventUsesVerifiedFieldsAndWorkspaceThread() {
        let h = handler(dir: tmp(), [a.id: material(a)])
        let r = h.handle(o: outerString(PushFixtures.sequence(nowMs: nowMs)[0]))
        #expect(r.presentation.title == a.name && r.presentation.body == PushFixtures.questionLabel)
        #expect(r.presentation.threadID == a.id.hex && r.presentation.entityKey == "\(a.id.hex)/\(PushFixtures.questionID)")
        #expect(r.presentation.sound && r.presentation.removesDelivered == nil && !r.presentation.simulated)
    }

    @Test func closureReplacesTheDeliveredQuestionAndSaysWhereItWasAnswered() {
        let h = handler(dir: tmp(), [a.id: material(a)])
        let seq = PushFixtures.sequence(nowMs: nowMs)
        let q = h.handle(o: outerString(seq[0])), c = h.handle(o: outerString(seq[1]))
        #expect(c.outcome == .closed && c.presentation.style == .closed)
        #expect(c.presentation.body == "Answered on laptop")
        #expect(c.presentation.removesDelivered == q.presentation.entityKey)
    }

    @Test func noMaterialLockedKeychainAndUnreadableStateAreGeneric() {
        let seq = PushFixtures.sequence(nowMs: nowMs)
        #expect(handler(dir: tmp(), [:]).handle(o: outerString(seq[0])).outcome == .droppedNoMaterial)
        let locked = handler(dir: tmp(), [:], fail: .locked).handle(o: outerString(seq[0]))
        #expect(locked.outcome == .droppedNoMaterial && locked.presentation == .generic)
        let nilO = handler(dir: tmp(), [a.id: material(a)]).handle(o: nil)
        #expect(nilO.presentation == .generic)
        // the state directory cannot be created: fail closed, generic
        let blocked = tmp(); let file = blocked.appendingPathComponent("push")
        try! Data().write(to: file)
        let r = handler(dir: file, [a.id: material(a)]).handle(o: outerString(seq[0]))
        #expect(r.presentation == .generic)
    }

    @Test func wrongKeyForThisWorkspaceNeverShows() {
        // material whose pinned WSK is not A's host key: a correctly sealed push fails the signature step
        let other = try! PushMaterial(generation: 1, name: "x", wsk: material(b).wsk, kPush: material(a).kPush)
        let h = handler(dir: tmp(), [a.id: other])
        #expect(h.handle(o: outerString(PushFixtures.sequence(nowMs: nowMs)[0])).outcome == .droppedVerification)
    }

    @Test func removedWorkspaceWritesNothingAndShowsGeneric() throws {
        let dir = tmp()
        let h = handler(dir: dir, [a.id: material(a)])
        let seq = PushFixtures.sequence(nowMs: nowMs)
        try TombstoneCoordination(directories: [dir]).write(TombstoneRecord(realm: "live", ws: a.id.hex, generation: 1))
        let r = h.handle(o: outerString(seq[0]))
        #expect(r.outcome == .droppedRemoved && r.presentation == .generic)
        #expect(!FileManager.default.fileExists(atPath: ReplayStore(pushDir: dir, realm: "live").stateDir(workspace: a.id).path), "no replay state after the tombstone")
        // a genuine rejoin (higher generation, new material) works again
        let again = handler(dir: dir, [a.id: material(a, generation: 2)]).handle(o: outerString(seq[0]))
        #expect(again.outcome == .shown)
    }

    @Test func testConcurrentPushWritersObserveTombstoneAndReplay() async throws {
        // 12 concurrent copies of one push (two NSE processes racing on one workspace): exactly one may show.
        let dir = tmp()
        let o = outerString(PushFixtures.sequence(nowMs: nowMs)[0])
        let results = try await withThrowingTaskGroup(of: NSEMarker.Outcome.self) { g in
            for _ in 0..<12 { g.addTask { handler(dir: dir, [PushFixtures.workspaceA.id: material(PushFixtures.workspaceA)]).handle(o: o).outcome } }
            return try await g.reduce(into: []) { $0.append($1) }
        }
        #expect(results.filter { $0 == .shown }.count == 1, "\(results)")
        #expect(results.filter { $0 == .droppedReplay }.count == 11)
        // a wipe racing the writers: after the tombstone lands nothing is written
        let dir2 = tmp()
        let coord = TombstoneCoordination(directories: [dir2])
        let f = PushFixtures.sequence(nowMs: nowMs)
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<6 { g.addTask { _ = handler(dir: dir2, [PushFixtures.workspaceA.id: material(PushFixtures.workspaceA)]).handle(o: outerString(f[i % 2 == 0 ? 0 : 7])) } }
            g.addTask { try? coord.write(TombstoneRecord(realm: "live", ws: PushFixtures.workspaceA.id.hex, generation: 1)) }
        }
        let store = ReplayStore(pushDir: dir2, realm: "live")
        let before = try store.load(workspace: PushFixtures.workspaceA.id, generation: 1)
        _ = handler(dir: dir2, [PushFixtures.workspaceA.id: material(PushFixtures.workspaceA)]).handle(o: outerString(f[7]))
        #expect(try store.load(workspace: PushFixtures.workspaceA.id, generation: 1) == before, "nothing is written once the tombstone exists")
    }

    @Test func markerHoldsNoContent() throws {
        let dir = tmp()
        let h = handler(dir: dir, [a.id: material(a)])
        for f in PushFixtures.sequence(nowMs: nowMs) { _ = h.handle(o: outerString(f)) }
        h.recordExpired()
        let text = String(decoding: try Data(contentsOf: dir.appendingPathComponent(NSEMarker.fileName)), as: UTF8.self)
        for secret in [PushFixtures.questionLabel, PushFixtures.questionID, a.name, a.id.hex, "laptop", "Real label"] {
            #expect(!text.contains(secret), "marker leaked \(secret)")
        }
        let m = NSEMarker.read(pushDir: dir)
        #expect(m?.count == 9 && m?.outcome == .expired && m!.atMs > 0)
        let keys = ((try JSONSerialization.jsonObject(with: Data(text.utf8))) as! [String: Any]).keys.sorted()
        #expect(keys == ["atMs", "count", "outcome"])
    }
}

struct PresentationTests {
    func payload(_ kind: String, label: String) -> PushProcessor.Payload {
        .init(workspace: PushFixtures.workspaceA.id, epoch: 1, kind: kind, id: "i", label: label, tsMs: 1)
    }

    @Test func labelsAreStrippedOfControlAndBidiCharacters() {
        let evil = "Pay \u{202E}0001 EUR\u{202C}\u{0007}\nnow\u{200B}!  "
        let p = PushPresentation.make(payload("question", label: evil), workspaceName: "W\u{202E}s")
        #expect(p.body == "Pay 0001 EUR now!" && p.title == "Ws")
        #expect(PushPresentation.make(payload("question", label: "\u{202E}\u{200B}"), workspaceName: "").body == PushPresentation.genericBody)
        #expect(PushPresentation.make(payload("question", label: "x"), workspaceName: "").title == PushPresentation.genericTitle)
    }

    @Test func joinIsVerifiedButNotDisplayed() {
        #expect(PushPresentation.make(payload("join", label: "someone"), workspaceName: "W") == .generic)
    }
}

struct MaterialTests {
    let a = PushFixtures.workspaceA

    @Test func codecRoundTripAndStrictness() throws {
        let m = material(a, generation: 7)
        #expect(try PushMaterial.decode(try m.encoded()) == m)
        #expect(m.generation == 7 && m.name == a.name && m.kPush == [1: a.kPush])
        let o = try StrictJSON.parse(try m.encoded(), maxBytes: 4096).object!
        func tweak(_ f: (inout [String: JSONValue]) -> Void) -> Data { var x = o; f(&x); return try! canonicalJSON(.object(x)) }
        #expect(throws: PushMaterialError.invalid) { try PushMaterial.decode(tweak { $0["extra"] = 1 }) }
        #expect(throws: PushMaterialError.invalid) { try PushMaterial.decode(tweak { $0["v"] = 2 }) }
        #expect(throws: PushMaterialError.invalid) { try PushMaterial.decode(tweak { $0["k"] = .object(["1": "AAAA"]) }) }
        #expect(throws: PushMaterialError.invalid) { try PushMaterial.decode(tweak { $0["k"] = .object(["01": .string(B64U.encode(Data(repeating: 1, count: 32)))]) }) }
        #expect(throws: PushMaterialError.invalid) { try PushMaterial.decode(tweak { $0["gen"] = -1 }) }
        #expect(throws: PushMaterialError.invalid) { try PushMaterial.decode(tweak { $0["wsk"] = "AAAA" }) }
        #expect(throws: PushMaterialError.invalid) { try PushMaterial.decode(Data(repeating: 0x20, count: PushMaterial.maxBytes + 1)) }
    }

    @Test func publisherWritesKPushNeverWK() throws {
        final class Sink: PushMaterialSink, @unchecked Sendable {
            var puts: [(realm: String, ws: String, purpose: String, data: Data)] = []
            func put(_ data: Data, realm: String, ws: String, purpose: String) throws { puts.append((realm, ws, purpose, data)) }
            func delete(realm: String, ws: String, purpose: String) throws {}
        }
        let sink = Sink()
        let wk = SymmetricKey(data: Data(repeating: 0x33, count: 32))
        try PushMaterialPublisher(sink: sink, realm: "live").publish(workspace: a.id, generation: 1, name: a.name, wsk: try SigningPublicKey(x963: a.wskPublic), wk: [1: wk])
        let put = try #require(sink.puts.first)
        #expect(put.realm == "live" && put.ws == a.id.hex && put.purpose == "push.material")
        let stored = try PushMaterial.decode(put.data)
        #expect(stored.kPush[1] == a.kPush, "K_push(ws, e) derived from WK")
        #expect(put.data.range(of: Data(repeating: 0x33, count: 32)) == nil && !String(decoding: put.data, as: UTF8.self).contains(B64U.encode(Data(repeating: 0x33, count: 32))), "WK must not appear")
        // the fixture's hand-written material is the same format the publisher writes
        #expect(try PushMaterial.decode(PushFixtures.materialJSON(a)) == stored)
        #expect(try PushMaterial.decode(PushFixtures.materialJSON(a)).encoded() == put.data)
    }
}

final class Recorder: LocalNotificationScheduling, @unchecked Sendable {
    private let lock = NSLock()
    var scheduled: [(PushPresentation, String)] = [], removed: [[String]] = []
    func schedule(_ p: PushPresentation, identifier: String) async { lock.withLock { scheduled.append((p, identifier)) } }
    func removeDelivered(identifiers: [String]) async { lock.withLock { removed.append(identifiers) } }
}

struct SimulationTests {
    let a = PushFixtures.workspaceA

    @Test func simulatesThroughTheSameProcessorAndLabelsItSimulated() async {
        let rec = Recorder()
        let sim = PushSimulator(materials: [a.id: material(a)], scheduler: rec, now: { Date(timeIntervalSince1970: Double(nowMs) / 1000) })
        let seq = PushFixtures.sequence(nowMs: nowMs)
        var outcomes: [String] = []
        for f in seq { outcomes.append(await sim.simulate(sealed: Data(outerString(f).utf8)).outcome.rawValue) }
        #expect(outcomes == seq.map(\.expectedOutcome), "same decisions as the extension")
        #expect(rec.scheduled.count == seq.count && rec.scheduled.allSatisfy { $0.0.simulated })
        #expect(rec.removed.flatMap { $0 } == ["sim/\(a.id.hex)/\(PushFixtures.questionID)"], "closure removes the simulated question")
        #expect(PushSimulator.label.lowercased().contains("simulated"))
    }
}
