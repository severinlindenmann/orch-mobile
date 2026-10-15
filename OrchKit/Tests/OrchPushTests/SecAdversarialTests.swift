import CryptoKit
import Foundation
import OrchProtocol
import OrchPushFixtures
import OrchCoordination
import Testing
@testable import OrchPush

struct SecAdversarialTests {
    let a = PushFixtures.workspaceA, b = PushFixtures.workspaceB
    func q(_ w: PushFixtures.Workspace, _ id: String, _ ts: Int64, label: String = "x", kind: String = "question") -> String {
        PushFixtures.seal(w, PushFixtures.payload(kind: kind, id: id, label: label, tsMs: ts))
    }

    // S1: corrupt state -> removed -> genuine replay within 24h shows again.
    @Test func corruptStateEnablesReplay() throws {
        let dir = tmp()
        let h = handler(dir: dir, [a.id: material(a)])
        let p = q(a, "q1", nowMs - 1000)
        #expect(h.handle(o: p).outcome == .shown)
        #expect(h.handle(o: p).outcome == .droppedReplay)
        let f = ReplayStore(pushDir: dir, realm: "live").fileURL(workspace: a.id, generation: 1)
        try Data("garbage".utf8).write(to: f)
        let r1 = h.handle(o: p).outcome
        let r2 = h.handle(o: p).outcome
        print("SEC S1 corrupt: first=\(r1) second=\(r2)")
        #expect(r1 == .droppedReplay && r2 == .droppedReplay, "corruption must not re-enable a push that was already shown")
        // only pushes strictly newer than the recovery are accepted afterwards
        #expect(h.handle(o: q(a, "q2", nowMs + 1)).outcome == .shown)
    }

    // S2: hostile A cannot suppress B, incl. A-signed push claiming outer ws = B.
    @Test func hostileAOuterClaimsB() {
        let dir = tmp()
        let h = handler(dir: dir, [a.id: material(a), b.id: material(b)])
        let sealedA = q(a, "z", nowMs + 299_000)
        // rewrite outer ws to B
        var o = try! JSONSerialization.jsonObject(with: Data(sealedA.utf8)) as! [String: Any]
        o["ws"] = b.id.hex
        let forged = String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!
        let r = h.handle(o: forged)
        #expect(r.presentation == .generic)
        #expect(h.handle(o: sealedA).outcome == .shown)
        #expect(h.handle(o: q(b, "z", nowMs - 23 * 3600_000)).outcome == .shown)
        #expect(try! ReplayStore(pushDir: dir, realm: "live").load(workspace: b.id, generation: 1)?.maxShownTs == nowMs - 23 * 3600_000)
        print("SEC S2 forged outer: \(r.outcome)")
    }

    // S3: leave + rejoin (state dir wiped, generation+1): relay replays a push shown under gen 1.
    @Test func rejoinResetsReplay() throws {
        let dir = tmp()
        let p = q(a, "q1", nowMs - 1000)
        #expect(handler(dir: dir, [a.id: material(a, generation: 1)]).handle(o: p).outcome == .shown)
        try TombstoneCoordination(directories: [dir]).write(TombstoneRecord(realm: "live", ws: a.id.hex, generation: 1))
        try FileManager.default.removeItem(at: ReplayStore(pushDir: dir, realm: "live").stateDir(workspace: a.id))
        let r = handler(dir: dir, [a.id: material(a, generation: 2)]).handle(o: p).outcome
        print("SEC S3 rejoin replay of old push: \(r)")
        #expect(r == .droppedReplay, "a rejoin must not reset replay protection")
    }

    // S4: ifNotRemoved with missing push dir runs body without a lock and sees no tombstones.
    @Test func missingDirRunsUnlocked() throws {
        let base = tmp().appendingPathComponent("nope", isDirectory: true)
        let ran = try TombstoneCoordination(directories: [base]).ifNotRemoved(realm: "live", ws: a.id.hex, generation: 1) { true }
        print("SEC S4 missing dir body ran: \(String(describing: ran)) lockExists=\(FileManager.default.fileExists(atPath: base.appendingPathComponent("tombstones.lock").path))")
        #expect(ran == true && FileManager.default.fileExists(atPath: base.appendingPathComponent("tombstones.lock").path), "the body always runs under a real lock")
    }

    // S5: corrupt tombstone file fails closed; generation rollback (older material than state) fails closed.
    @Test func corruptTombstoneAndRollback() throws {
        let dir = tmp()
        let p = q(a, "q1", nowMs - 1000)
        #expect(handler(dir: dir, [a.id: material(a, generation: 3)]).handle(o: p).outcome == .shown)
        let r = handler(dir: dir, [a.id: material(a, generation: 2)]).handle(o: q(a, "q2", nowMs))
        print("SEC S5 rollback material: \(r.outcome)")
        try Data("{".utf8).write(to: dir.appendingPathComponent("tombstones.json"))
        let r2 = handler(dir: dir, [a.id: material(a, generation: 3)]).handle(o: q(a, "q3", nowMs))
        print("SEC S5 corrupt tombstone: \(r2.outcome)")
        #expect(r.presentation == .generic && r2.presentation == .generic)
    }

    // S6: label spoofing: bidi, newlines, zero width, combining flood, very long id.
    @Test func labelAndIdHostile() {
        let dir = tmp()
        let h = handler(dir: dir, [a.id: material(a)])
        let label = "\u{202E}evil\u{200B}\u{2066}\n\n\u{2028}line" + String(repeating: "e\u{0301}\u{0301}\u{0301}", count: 10)
        let longID = String(repeating: "/", count: 1500)
        let r = h.handle(o: q(a, longID, nowMs, label: label))
        #expect(r.presentation == .generic, "an id over \(PushProcessor.maxIDBytes) bytes is refused")
        let ok = h.handle(o: q(a, "ok", nowMs, label: label))
        #expect(ok.outcome == .shown && !ok.presentation.body.unicodeScalars.contains { [0x202E, 0x200B, 0x2066, 0x2028, 0x0A].contains($0.value) })
        print("SEC S6 outcome=\(r.outcome) body=\(r.presentation.body.unicodeScalars.map { String($0.value, radix: 16) }.prefix(20)) key.len=\(r.presentation.entityKey?.utf8.count ?? -1) thread=\(r.presentation.threadID ?? "nil")")
    }

    // S7: id canonical equivalence: "é" precomposed vs decomposed are distinct ids (byte keyed), and both shown.
    @Test func idByteKeyed() {
        let dir = tmp()
        let h = handler(dir: dir, [a.id: material(a)])
        let r1 = h.handle(o: q(a, "\u{00E9}", nowMs - 10)).outcome
        let r2 = h.handle(o: q(a, "e\u{0301}", nowMs - 10)).outcome
        print("SEC S7 nfc=\(r1) nfd=\(r2)")
    }

    // S8: marker bytes contain no ws hex / label / name.
    @Test func markerNoLeak() throws {
        let dir = tmp()
        _ = handler(dir: dir, [a.id: material(a)]).handle(o: q(a, "secret-id", nowMs, label: "SECRETLABEL"))
        let s = String(decoding: try Data(contentsOf: dir.appendingPathComponent(NSEMarker.fileName)), as: UTF8.self)
        print("SEC S8 marker=\(s)")
        #expect(!s.contains("SECRET") && !s.contains(a.id.hex) && !s.contains("secret-id"))
    }

    // S9: state growth by a hostile host is bounded: ids are hashed and the table is capped (refuse, never evict).
    @Test func stateGrowthIsBounded() throws {
        let dir = tmp()
        let h = handler(dir: dir, [a.id: material(a)])
        let id = String(repeating: "x", count: PushProcessor.maxIDBytes - 4)
        var outcomes: [NSEMarker.Outcome] = []
        for i in 0..<(PushProcessor.maxEntriesPerWorkspace + 20) { outcomes.append(h.handle(o: q(a, id + String(format: "%04d", i), nowMs - 600 + Int64(i))).outcome) }
        #expect(outcomes.prefix(PushProcessor.maxEntriesPerWorkspace).allSatisfy { $0 == .shown })
        #expect(outcomes.suffix(20).allSatisfy { $0 == .droppedState }, "full table: refuse to show, generic text")
        let f = ReplayStore(pushDir: dir, realm: "live").fileURL(workspace: a.id, generation: 1)
        let size = try Data(contentsOf: f).count
        #expect(size < 64 * 1024, "state bytes \(size)")
        // an id already in the table still advances (a closure of a known question is not refused)
        #expect(h.handle(o: q(a, id + "0000", nowMs + 5, kind: "question.closed")).outcome == .closed)
    }
}
