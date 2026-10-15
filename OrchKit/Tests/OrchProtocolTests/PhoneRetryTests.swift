import Foundation
import Testing
@testable import OrchProtocol

@Suite struct PhoneRetryTests {
    static let now: Int64 = 1_790_000_000_000
    static let eventID = try! ULID.make(timeMs: now, random: Data(count: 10))
    func ctx(at: Int64 = now, admitted: Bool = false, absent: Bool? = nil) -> PhoneRefusalContext {
        PhoneRefusalContext(eventID: Self.eventID, hostNowMs: at, admitted: admitted, logShowsEventAbsent: absent)
    }

    @Test func classTable() {
        let table: [(PhoneRetryClass, [String])] = [
            (.a, ["stale_epoch", "stale_timestamp", "stale_sequence", "silence", "no_answer", "relay.timeout", "relay.silence", "relay.stale_epoch_hint", "cancelled", "store.busy", "lock.busy",
                  "busy", "rate.limited", "quota.host", "host.restarting", "conn.overloaded", "outcome.unknown"]),
            (.b, ["already_done.unknown", "rid_conflict", "outcome.pending", "idem.expired"]),
            (.cAuto, ["members.stale", "ticket.key_not_next"]),
            (.cReview, ["event.bad_base", "question.stale", "event.expired", "event.abandoned"]),
            (.d, ["committed", "failed.landed", "timeout", "question.answered", "question.unknown", "answer.not_allowed", "answer.bad_option", "role.denied",
                  "member.unknown", "device.scope", "device.invalid", "device.unknown", "ticket.frozen", "freeze.active", "ticket.not_visible",
                  "not_found", "ticket.exists", "ticket.bad_reference", "event.duplicate_id", "forbidden_scope", "op.not_allowed", "sig.invalid",
                  "validation.event", "validation.text", "invalid.input", "idem.conflict", "idem.required"]),
        ]
        for (cls, codes) in table { for code in codes { #expect(PhoneRetryTable.classify(code, ctx()) == cls, "\(code)") } }
    }

    @Test func classSetsAreDisjointAndKnownCodesCoverThem() {
        let sets = [PhoneRetryTable.classA, PhoneRetryTable.classB, PhoneRetryTable.classCAuto, PhoneRetryTable.classCReview, PhoneRetryTable.classD]
        let total = sets.reduce(0) { $0 + $1.count }
        #expect(Set(sets.flatMap { $0 }).count == total)
        #expect(PhoneRetryTable.knownCodes.count == total + 2)
    }

    @Test func unknownCodeIsD() {
        #expect(PhoneRetryTable.classify("something.new", ctx()) == .d)
        #expect(PhoneRetryTable.classify("", ctx()) == .d)
        #expect(PhoneRetryTable.classify("Event.Expired", ctx()) == .d)
    }

    @Test func retryableIsDerivedFromTheClass() {
        #expect(PhoneRetryClass.a.retryable)
        #expect(PhoneRetryClass.b.retryable)
        #expect(!PhoneRetryClass.cAuto.retryable)
        #expect(!PhoneRetryClass.cReview.retryable)
        #expect(!PhoneRetryClass.d.retryable)
        #expect(PhoneRetryClass.cAuto.isDefinite)
        #expect(!PhoneRetryClass.b.isDefinite)
    }

    @Test func internalIsDExceptAfterAdmission() {
        #expect(PhoneRetryTable.classify("internal", ctx(admitted: false)) == .d)
        #expect(PhoneRetryTable.classify("internal", ctx(admitted: true)) == .b)
    }

    @Test func unknownIdemDependsOnTheBound() {
        let bound = Self.now + PhoneRetryTable.unknownIdemBoundMs
        #expect(PhoneRetryTable.classify("outcome.unknown_idem", ctx(at: bound - 1, absent: true)) == .b)
        #expect(PhoneRetryTable.classify("outcome.unknown_idem", ctx(at: bound, absent: true)) == .cReview)
        #expect(PhoneRetryTable.classify("outcome.unknown_idem", ctx(at: bound, absent: false)) == .d)
        #expect(PhoneRetryTable.classify("outcome.unknown_idem", ctx(at: bound + 5, absent: nil)) == .b)
        // an unparseable event id has no bound to wait for: D, never an unbounded retry
        #expect(PhoneRetryTable.classify("outcome.unknown_idem", PhoneRefusalContext(eventID: "bad", hostNowMs: bound)) == .d)
        #expect(PhoneRetryTable.unknownIdemBoundMs == 900_000 + 300_000)
    }
}

@Suite struct AutoResignTests {
    let answerDisplay = ReviewDisplay.answer(AnswerDisplay(qid: "q", hash: "h", option: "csv", text: nil, to: ["p_1"], why: "w", recommended: "csv", blocking: true))
    let creation = ReviewDisplay.creation(CreationDisplay(ticketType: "feature", title: "T", owner: "p_1"))
    let prevAnswer: [String: JSONValue] = ["roster_v": 3, "id": "A", "sig": "s1", "based_on": "h1", "hash": "x", "question": "Q1"]
    let prevCreate: [String: JSONValue] = ["roster_v": 3, "id": "A", "sig": "s1", "based_on": .null, "key": "DEMO-0013", "title": "T"]

    func answerInput() -> AutoResignInput {
        var p = prevAnswer; p["roster_v"] = 4; p["id"] = "B"; p["sig"] = "s2"
        return AutoResignInput(lastClass: .cAuto, lastAnswerWasRefusedForExactIdem: true, earlierIdemUnresolved: false, reviewed: answerDisplay,
                               fresh: answerDisplay, previous: prevAnswer, proposed: p, previousLog: "U", proposedLog: "U", keyAssignedDisclosed: false,
                               foregroundAndUnlockedSinceTap: true, autoResignsSoFar: 0)
    }
    func createInput() -> AutoResignInput {
        var p = prevCreate; p["roster_v"] = 4; p["id"] = "B"; p["key"] = "DEMO-0014"; p["sig"] = "s2"
        var i = answerInput()
        i.reviewed = creation; i.fresh = creation; i.previous = prevCreate; i.proposed = p; i.keyAssignedDisclosed = true
        return i
    }

    @Test func allowsTheDecidedCases() {
        #expect(AutoResign.decide(answerInput()) == .allow)
        #expect(AutoResign.decide(createInput()) == .allow)
        var i = createInput(); i.autoResignsSoFar = 2
        #expect(AutoResign.decide(i) == .allow)
    }

    @Test func eachConditionDenies() {
        for cls in [PhoneRetryClass.a, .b, .cReview, .d] {
            var i = answerInput(); i.lastClass = cls
            #expect(AutoResign.decide(i) == .deny(.notCAuto))
        }
        var i = answerInput(); i.lastAnswerWasRefusedForExactIdem = false
        #expect(AutoResign.decide(i) == .deny(.notRefusedForExactIdem))
        i = answerInput(); i.earlierIdemUnresolved = true
        #expect(AutoResign.decide(i) == .deny(.earlierIdemUnresolved))
        i = answerInput(); i.foregroundAndUnlockedSinceTap = false
        #expect(AutoResign.decide(i) == .deny(.notForegroundUnlocked))
        i = answerInput(); i.autoResignsSoFar = 3
        #expect(AutoResign.decide(i) == .deny(.limitReached))
        i = createInput(); i.keyAssignedDisclosed = false
        #expect(AutoResign.decide(i) == .deny(.keyDisclosureMissing))
        i = answerInput(); i.proposedLog = "V"
        #expect(AutoResign.decide(i) == .deny(.logChanged))
    }

    @Test func anyDisplayedFieldChangeDenies() {
        func fresh(_ f: (AnswerDisplay) -> AnswerDisplay) -> ReviewDisplay {
            guard case .answer(let a) = answerDisplay else { fatalError() }
            return .answer(f(a))
        }
        let changes: [ReviewDisplay] = [
            fresh { AnswerDisplay(qid: "q2", hash: $0.hash, option: $0.option, text: $0.text, to: $0.to, why: $0.why, recommended: $0.recommended, blocking: $0.blocking) },
            fresh { AnswerDisplay(qid: $0.qid, hash: "h2", option: $0.option, text: $0.text, to: $0.to, why: $0.why, recommended: $0.recommended, blocking: $0.blocking) },
            fresh { AnswerDisplay(qid: $0.qid, hash: $0.hash, option: "api", text: $0.text, to: $0.to, why: $0.why, recommended: $0.recommended, blocking: $0.blocking) },
            fresh { AnswerDisplay(qid: $0.qid, hash: $0.hash, option: $0.option, text: "t", to: $0.to, why: $0.why, recommended: $0.recommended, blocking: $0.blocking) },
            fresh { AnswerDisplay(qid: $0.qid, hash: $0.hash, option: $0.option, text: $0.text, to: ["p_2"], why: $0.why, recommended: $0.recommended, blocking: $0.blocking) },
            fresh { AnswerDisplay(qid: $0.qid, hash: $0.hash, option: $0.option, text: $0.text, to: $0.to, why: "other", recommended: $0.recommended, blocking: $0.blocking) },
            fresh { AnswerDisplay(qid: $0.qid, hash: $0.hash, option: $0.option, text: $0.text, to: $0.to, why: $0.why, recommended: "api", blocking: $0.blocking) },
            fresh { AnswerDisplay(qid: $0.qid, hash: $0.hash, option: $0.option, text: $0.text, to: $0.to, why: $0.why, recommended: $0.recommended, blocking: false) },
        ]
        for f in changes {
            var i = answerInput(); i.fresh = f
            #expect(AutoResign.decide(i) == .deny(.displayedFieldChanged))
        }
        for f in [CreationDisplay(ticketType: "bug", title: "T", owner: "p_1"), CreationDisplay(ticketType: "feature", title: "T2", owner: "p_1"),
                  CreationDisplay(ticketType: "feature", title: "T", owner: "p_2")] {
            var i = createInput(); i.fresh = .creation(f)
            #expect(AutoResign.decide(i) == .deny(.displayedFieldChanged))
        }
        var i = answerInput(); i.fresh = creation
        #expect(AutoResign.decide(i) == .deny(.displayedFieldChanged))
    }

    @Test func onlyRosterIdSigAndForACreationKeyMayChange() {
        var i = answerInput(); i.proposed["based_on"] = "h2"
        #expect(AutoResign.decide(i) == .deny(.unexpectedFieldChanged("based_on")))
        i = answerInput(); i.proposed["hash"] = "other"
        #expect(AutoResign.decide(i) == .deny(.unexpectedFieldChanged("hash")))
        i = answerInput(); i.proposed["key"] = "DEMO-0001"   // a key appearing on an answer
        #expect(AutoResign.decide(i) == .deny(.unexpectedFieldChanged("key")))
        i = answerInput(); i.proposed["text"] = "new"
        #expect(AutoResign.decide(i) == .deny(.unexpectedFieldChanged("text")))
        i = createInput(); i.proposed["title"] = "T2"
        #expect(AutoResign.decide(i) == .deny(.unexpectedFieldChanged("title")))
        i = createInput(); i.proposed["based_on"] = "h"
        #expect(AutoResign.decide(i) == .deny(.unexpectedFieldChanged("based_on")))
        i = createInput(); i.proposed["owner"] = "p_9"
        #expect(AutoResign.decide(i) == .deny(.unexpectedFieldChanged("owner")))
    }
}
