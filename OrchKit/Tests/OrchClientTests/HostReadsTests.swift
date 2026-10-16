import Foundation
import Testing
import OrchProtocol
@testable import OrchClient

/// The typed parsers of the column-R reads: bound and displayed fields are checked exactly, every other key of an unsigned host view is ignored.
@Suite struct HostReadsTests {
    let uid = "01J9ZK4Q7M3R8T2V6X0B5N1C9D"
    let person = "p_75bf75a3bb50b0c4ac02f8a757b90e23"
    let device = "d_0286b57b640b02aea012e01129db9dcb"
    let hash = "sha256:" + String(repeating: "a", count: 64)

    func needs(_ item: [String: JSONValue] = [:]) -> JSONValue {
        var i: [String: JSONValue] = ["kind": "question", "key": "MOB-0001", "uid": .string(uid), "ref": "Q1", "detail": "blocking", "who": [.string(person)],
                                      "since": "2026-10-15T10:00:00Z", "text": "Which?", "status": "open",
                                      "payload": ["question": "Q1", "blocking": true, "to": .string(person), "options": [["key": "a", "label": "A"]]]]
        for (k, v) in item { i[k] = v }
        return ["items": [.object(i)], "sub_cursor": "j:1"]
    }

    @Test func needsParsesAQuestionItemAndIgnoresUnknownKeys() throws {
        var v = needs(["surprise": 1])
        var o = v.object!; o["extra"] = true; v = .object(o)
        let r = try NeedsResult(v)
        #expect(r.subCursor == "j:1" && r.items.count == 1)
        let i = r.items[0]
        #expect(i.kind == .question && i.key == "MOB-0001" && i.uid == uid && i.ref == "Q1" && i.sinceMs == 1_792_058_400_000 && !i.textCut)
        guard case .question(let id, let blocking, _, _, _)? = i.payload else { Issue.record("payload"); return }
        #expect(id == "Q1" && blocking)
    }

    @Test func needsRefusesWhatItDepends() {
        #expect(throws: ViewError.malformed) { _ = try NeedsResult(needs(["uid": .null])) }                         // key without uid
        #expect(throws: ViewError.malformed) { _ = try NeedsResult(needs(["who": ["someone"]])) }
        #expect(throws: ViewError.malformed) { _ = try NeedsResult(needs(["ref": "Q2"])) }                           // payload names another question
        #expect(throws: ViewError.malformed) { _ = try NeedsResult(needs(["since": "yesterday"])) }
        #expect(throws: ViewError.malformed) { _ = try NeedsResult(["items": [], "sub_cursor": ""]) }
        // an item of a kind this phone does not know is left out, not fatal
        #expect((try? NeedsResult(needs(["kind": "novel"])))?.items.isEmpty == true)
    }

    @Test func ticketQueryRows() throws {
        let row: JSONValue = ["key": "MOB-0001", "uid": .string(uid), "title": "T", "type": "ticket", "status": "in_progress", "parent": "FAC-0001", "epic": "FAC-0001",
                              "updated_at": "2026-10-15T10:00:00.250Z", "head_seq": 3, "labels": [], "blocking_questions": 2, "anything": "else"]
        let p = try TicketPage(["rows": [row], "next_page": .null, "total": 1, "sub_cursor": "j:3", "as_of": "2026-10-15T10:00:01Z"])
        #expect(p.rows[0].updatedMs == 1_792_058_400_250 && p.rows[0].blockingQuestions == 2 && p.nextPage == nil)
        #expect(Ticket(row: p.rows[0]).state == "in_progress" && Ticket(row: p.rows[0]).epicKey == "FAC-0001")
        var bad = row.object!; bad["head_seq"] = -1
        #expect(throws: ViewError.malformed) { _ = try TicketPage(["rows": [.object(bad)], "next_page": .null, "total": 1, "sub_cursor": "j", "as_of": "2026-10-15T10:00:01Z"]) }
        #expect(throws: ViewError.malformed) { _ = try TicketPage(["rows": [row, row], "next_page": .null, "total": 2, "sub_cursor": "j", "as_of": "2026-10-15T10:00:01Z"]) }
    }

    @Test func ticketGetNeedsTheBoundFields() throws {
        let q: JSONValue = ["id": "Q1", "state": "open", "to": [.string(person)], "blocking": true, "answered_by": .null, "answered_seq": .null, "text": "Which?"]
        func get(_ edit: (inout [String: JSONValue]) -> Void = { _ in }) -> JSONValue {
            var o: [String: JSONValue] = ["doc": ["uid": .string(uid), "key": "MOB-0001", "title": "T", "type": "ticket", "status": "open", "head": ["seq": 4, "head": .string(hash)]],
                                          "log": [], "log_more": false, "questions": [q, ["garbage": 1]], "criteria": [], "gates": [:], "sub_cursor": "j:4", "members_v": 7]
            edit(&o)
            return .object(o)
        }
        let t = try TicketGet(get())
        #expect(t.uid == uid && t.headSeq == 4 && t.headHash == hash && t.membersV == 7 && t.questions.count == 2)
        #expect(t.questions[0].question?.id == "Q1")
        #expect(t.questions[1] == .unreadable(id: nil))               // a bad entry does not take the others with it
        #expect(throws: ViewError.malformed) { _ = try TicketGet(get { $0["members_v"] = nil }) }
        #expect(throws: ViewError.malformed) { _ = try TicketGet(get { var d = $0["doc"]!.object!; d["head"] = nil; $0["doc"] = .object(d) }) }
        #expect(throws: ViewError.malformed) { _ = try TicketGet(get { var d = $0["doc"]!.object!; d["uid"] = "nope"; $0["doc"] = .object(d) }) }
        #expect(throws: ViewError.malformed) { _ = try TicketGet(get { $0["questions"] = [q, q] }) }       // duplicate question id
    }

    @Test func memberListAndWorkspaceShow() throws {
        let m = try MemberListResult(["members": [["person": .string(person), "name": "Ann", "role": "owner",
            "devices": [["id": .string(device), "auth": .null, "scopes": ["look", "decide"], "valid": true, "label": "Phone", "paired_at": .null, "relay": true,
                         "cert_expires_at": "2027-01-01T00:00:00Z", "reader": 1, "future": 9]]]], "required_reader": 1])
        #expect(m.members[0].devices[0].label == "Phone" && m.members[0].devices[0].reader == 1 && m.requiredReader == 1)
        #expect(throws: ViewError.malformed) { _ = try MemberListResult(["members": [["person": "x", "name": "A", "role": "owner", "devices": []]]]) }
        func show(_ edit: (inout [String: JSONValue]) -> Void = { _ in }) -> JSONValue {
            var o: [String: JSONValue] = ["id": .string(String(repeating: "a", count: 32)), "prefix": "MOB", "name": "W", "genesis": .string(hash), "epoch": 2,
                                          "wsk_fingerprint": "x", "members_v": 7, "state": "ok", "next_key": "MOB-0012", "required_reader": 0]
            edit(&o)
            return .object(o)
        }
        #expect(try WorkspaceShowResult(show()).nextKey == "MOB-0012")
        #expect(try WorkspaceShowResult(show { $0["next_key"] = .null }).nextKey == nil)
        #expect(try WorkspaceShowResult(show { $0["next_key"] = nil }).nextKey == nil)
        #expect(throws: ViewError.malformed) { _ = try WorkspaceShowResult(show { $0["state"] = "weird" }) }
        #expect(throws: ViewError.malformed) { _ = try WorkspaceShowResult(show { $0["next_key"] = "lowercase-1" }) }
        #expect(throws: ViewError.malformed) { _ = try WorkspaceShowResult(show { $0["members_v"] = nil }) }
    }

    @Test func activityOutcomeWhoamiReaders() throws {
        let item: JSONValue = ["id": "01J9ZK4Q7M3R8T2V6X0B5N1C9D", "jpos": 12, "log": .string(uid), "key": "MOB-0001", "uid": .string(uid), "title": "T", "seq": 3, "ws_seq": 9,
                               "type": "question.answered", "at": "2026-10-15T10:00:00Z", "actor": ["kind": "person"], "summary": "s", "data": [:]]
        let a = try ActivityPage(["items": [item], "next_page": .null, "sub_cursor": "j:12", "as_of": "2026-10-15T10:00:01Z"])
        #expect(a.items[0].jpos == 12 && a.subCursor == "j:12")
        #expect(try OutcomeResult(["state": "pending"]).state == .pending)
        let partial = try OutcomeResult(["state": "partial", "error": ["code": "invalid.input"], "exit": 5, "seqs": [7]])
        #expect(partial.seqs == [7] && partial.errorCode == "invalid.input")
        #expect(try OutcomeResult(["state": "failed", "error": ["code": "ticket.exists"], "exit": 5]).seqs == nil)
        #expect(throws: ViewError.malformed) { _ = try OutcomeResult(["state": "failed", "exit": 5]) }               // failed without a code
        #expect(throws: ViewError.malformed) { _ = try OutcomeResult(["state": "partial", "error": ["code": "x"], "exit": 5, "seqs": []]) }
        #expect(try WhoAmIResult(["peer": ["uid": -1, "class": "person"], "person": .string(person), "tier": "A", "grant": .null, "session": .null]).person == person)
        let readers = try ReaderListResult(["readers": [["device": .string(device), "person": .string(person), "reader": 1, "level": 1]], "required_reader": 1])
        #expect(readers.readers.count == 1 && readers.requiredReader == 1)
        // reader.list is not in the closed op table: the phone cannot call it
        #expect(R2.ops["reader.list"] == nil)
    }

    @Test func timeParsing() {
        #expect(HostTime.ms("1970-01-01T00:00:00Z") == 0)
        #expect(HostTime.ms("2024-02-29T12:00:00Z") == 1_709_208_000_000)
        #expect(HostTime.ms("2023-02-29T12:00:00Z") == nil)
        #expect(HostTime.ms("2026-10-15T10:00:00+00:00") == nil)
        #expect(HostTime.ms("2026-10-15 10:00:00Z") == nil)
        #expect(HostTime.ms("2026-10-15T10:00:00.5Z") == HostTime.ms("2026-10-15T10:00:00Z")! + 500)
    }

    @Test func resultEnvelopeToleratesUnknownKeysAndChecksTypes() throws {
        let r = try HostResult(parsing: Data(#"{"data":{"a":1},"exit":0,"duplicate":true,"seq":3,"unknown":[1]}"#.utf8))
        #expect(r.duplicate && r.seq == 3 && r.data == ["a": 1] && r.hints.isEmpty)
        #expect(throws: ViewError.malformed) { _ = try HostResult(parsing: Data(#"{"data":1}"#.utf8)) }
        #expect(throws: ViewError.malformed) { _ = try HostResult(parsing: Data(#"{"data":1,"exit":0,"hints":[1]}"#.utf8)) }
        #expect(throws: ViewError.malformed) { _ = try HostResult(parsing: Data(#"{"data":1,"exit":0,"seq":-1}"#.utf8)) }
        #expect(throws: ViewError.malformed) { _ = try HostResult(parsing: Data("[]".utf8)) }
    }
}

@Suite struct HostWriteSupportTests {
    private func who(_ relay: JSONValue?) throws -> WhoAmIResult {
        var o: [String: JSONValue] = ["peer": ["uid": -1, "class": "person"], "person": "p_x", "tier": "A", "grant": .null, "session": .null]
        if let relay { o["relay"] = relay }
        return try WhoAmIResult(.object(o))
    }

    /// The shape of host changelog 57 / `Dispatch._relay_caps`.
    @Test func parsesTheHostShapeAndIgnoresDev() throws {
        let r = try who(["ops": ["answer": 1, "new_ticket": 1], "r6_ready": true, "dev": ["sim_convenience": true, "sandbox": "abcd1234"]]).relay
        #expect(r == HostWriteSupport(ops: ["answer": 1, "new_ticket": 1], r6Ready: true))
        #expect(r?.allows("answer") == true && r?.allows("new_ticket") == true)
        #expect(try who(["ops": ["answer": 1], "r6_ready": false]).relay?.allows("answer") == false)
    }

    @Test func absentOrMalformedIsNilAndNeverFailsTheRead() throws {
        #expect(try who(nil).relay == nil)
        for bad: JSONValue in [.null, "x", 1, [], ["ops": ["answer": 1]], ["r6_ready": true], ["ops": [], "r6_ready": true],
                               ["ops": ["answer": 1], "r6_ready": "yes"], ["ops": ["answer": 1], "r6_ready": 1]] {
            let w = try who(bad)
            #expect(w.relay == nil && w.person == "p_x")
        }
    }

    @Test func onlyVersionOneOfAnOpWithR6ReadyIsAllowed() throws {
        let ready = HostWriteSupport(ops: ["answer": 1, "new_ticket": 2, "other": 1], r6Ready: true)
        #expect(ready.allows("answer") && !ready.allows("new_ticket") && !ready.allows("unlisted"))
        #expect(!HostWriteSupport(ops: ["answer": 1], r6Ready: false).allows("answer"))
        // a malformed op value drops that op, not the others
        let partial = try who(["ops": ["answer": 1, "new_ticket": "1"], "r6_ready": true]).relay
        #expect(partial?.allows("answer") == true && partial?.allows("new_ticket") == false)
    }
}
