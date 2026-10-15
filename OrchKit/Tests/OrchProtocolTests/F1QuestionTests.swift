import Foundation
import Testing
@testable import OrchProtocol

@Suite struct F1QuestionTests {
    let hashes = F1Vectors.load("hashes")
    let labels = F1Vectors.load("labels")
    let wsid = ID16(hex: "0123456789abcdef0123456789abcdef")!

    func options(_ v: JSONValue) -> [F1QuestionOption] {
        v.items.map { F1QuestionOption(key: $0["key"].str, label: $0["label"].str, cost: $0["cost"].string) }
    }

    @Test func labelsMatchCore() {
        #expect(labels["labels"]["sig_ticket_event"].str == Label.sigTicketEvent)
        #expect(labels["labels"]["question"].str == Label.hQuestion)
        #expect(labels["labels"]["question_id"].str == Label.hQuestionID)
    }

    @Test func questionIDKnownAnswers() throws {
        let cases = hashes["question_id"].items
        #expect(!cases.isEmpty)
        for c in cases {
            let got = try F1Question.questionID(question: c["question"].str, ticketUID: c["ticket"].str, workspace: ID16(hex: c["workspace_id"].str)!)
            #expect(got == c["qid"].str)
        }
    }

    @Test func questionHashKnownAnswers() throws {
        let cases = hashes["question_hash"].items
        #expect(cases.count >= 2)
        for c in cases {
            let got = try F1Question.questionHash(qid: c["qid"].str, ticketUID: c["ticket"].str, text: c["text"].str, options: options(c["options"]))
            #expect(got == c["hash"].str)
        }
    }

    @Test func questionHashRefusesTextThatBreaksTheRules() {
        for c in hashes["question_hash_refused"].items {
            let r = try? F1Question.questionHash(qid: String(repeating: "a", count: 32), ticketUID: "01J9ZK4Q7M3R8T2V6X0B5N1C9D",
                                                text: c["text"].str, options: options(c["options"]))
            #expect(r == nil)
        }
    }

    // MARK: parser

    func ticketGetQuestion(_ extra: [String: JSONValue] = [:], drop: [String] = []) -> JSONValue {
        var q: [String: JSONValue] = ["id": "Q1", "state": "open", "to": ["p_75bf75a3bb50b0c4ac02f8a757b90e23"], "blocking": true,
                                      "answered_by": .null, "answered_seq": .null, "text": "Which?", "why": "because",
                                      "options": [["key": "csv", "label": "CSV", "cost": "1 day"], ["key": "api", "label": "API"]],
                                      "recommended": "csv"]
        for (k, v) in extra { q[k] = v }
        for k in drop { q[k] = nil }
        return .object(q)
    }

    @Test func parsesAnOpenQuestion() throws {
        let q = try F1Question(ticketGetQuestion())
        #expect(q.id == "Q1")
        #expect(q.state == .open)
        #expect(q.options.count == 2)
        #expect(q.options[0].cost == "1 day")
        #expect(q.options[1].cost == nil)
        #expect(q.answer == nil)
    }

    @Test func optionsAbsentMeansEmpty() throws {
        let q = try F1Question(ticketGetQuestion(drop: ["options", "recommended"]))
        #expect(q.options.isEmpty)
        let e = try F1Question(ticketGetQuestion(["options": []], drop: ["recommended"]))
        #expect(e.options.isEmpty)
    }

    @Test func refusesUnknownKeyMissingKeyAndBadTypes() {
        #expect((try? F1Question(ticketGetQuestion(["surprise": 1]))) == nil)
        #expect((try? F1Question(ticketGetQuestion(drop: ["blocking"]))) == nil)
        #expect((try? F1Question(ticketGetQuestion(["id": "Q01"]))) == nil)
        #expect((try? F1Question(ticketGetQuestion(["state": "closed"]))) == nil)
        #expect((try? F1Question(ticketGetQuestion(["to": ["sev"]]))) == nil)
        #expect((try? F1Question(ticketGetQuestion(["recommended": "nope"]))) == nil)
        #expect((try? F1Question(ticketGetQuestion(["options": [["key": "a", "label": "A", "extra": 1]]], drop: ["recommended"]))) == nil)
        #expect((try? F1Question(ticketGetQuestion(["options": [["key": "a", "label": "A"], ["key": "a", "label": "B"]], "recommended": "a"]))) == nil)
        #expect((try? F1Question(ticketGetQuestion(["qid": "xyz"]))) == nil)
    }

    @Test func refusesTextThatBreaksTheRules() {
        #expect((try? F1Question(ticketGetQuestion(["text": "cafe\u{301}"]))) == nil)
        #expect((try? F1Question(ticketGetQuestion(["options": [["key": "a", "label": "bad\u{202E}"]], "recommended": "a"]))) == nil)
    }

    func answered(auth: JSONValue = "secure-enclave-unlocked", signerAuth: JSONValue = "secure-enclave-unlocked") -> JSONValue {
        let answer: JSONValue = ["by": "p_75bf75a3bb50b0c4ac02f8a757b90e23", "at": "2026-10-10T10:01:10Z", "seq": 3, "option": "csv", "text": .null,
                                 "auth": auth, "id": "01M4JM4RKG79RG3QTWCP60NNNG",
                                 "signer": ["device": "d_762df76def3afcc7bfc48dbc595f8add", "auth": signerAuth]]
        return ticketGetQuestion(["state": "answered", "answered_by": "p_75bf75a3bb50b0c4ac02f8a757b90e23", "answered_seq": 3, "answer": answer])
    }

    @Test func parsesAnAnswerWithSigner() throws {
        let q = try F1Question(answered())
        #expect(q.answer?.id == "01M4JM4RKG79RG3QTWCP60NNNG")
        #expect(q.answer?.signerAuth == .secureEnclaveUnlocked)
        #expect(q.answer?.signerDevice == "d_762df76def3afcc7bfc48dbc595f8add")
        #expect(q.answer?.auth == .secureEnclaveUnlocked)
    }

    @Test func unknownAuthValuesAreRefused() {
        #expect((try? F1Question(answered(auth: "fingerprint"))) == nil)
        #expect((try? F1Question(answered(signerAuth: "root"))) == nil)
        #expect((try? F1Question(answered(auth: 1))) == nil)
        #expect((try? F1Question(answered(auth: "passphrase"))) != nil)
        for a in F1Auth.allCases { #expect((try? F1Question(answered(auth: .string(a.rawValue)))) != nil) }
    }

    @Test func answerStateAndAnswerGoTogether() {
        #expect((try? F1Question(ticketGetQuestion(["state": "answered"]))) == nil)
        let a = answered().object!["answer"]!
        #expect((try? F1Question(ticketGetQuestion(["answer": a]))) == nil)
    }

    @Test func answerNeedsOptionOrText() {
        let a: JSONValue = ["by": "p_75bf75a3bb50b0c4ac02f8a757b90e23", "at": "t", "seq": 3, "option": .null, "text": .null, "id": "01M4JM4RKG79RG3QTWCP60NNNG"]
        #expect((try? F1Question(ticketGetQuestion(["state": "answered", "answer": a]))) == nil)
    }

    // MARK: reviewed (recomputed qid and hash)

    @Test func reviewedRecomputesAndComparesToTheHost() throws {
        let ticket = "01J9ZK4Q7M3R8T2V6X0B5N1C9D"
        let opts: [F1QuestionOption] = [F1QuestionOption(key: "csv", label: "CSV", cost: "1 day"), F1QuestionOption(key: "api", label: "API")]
        let qid = try F1Question.questionID(question: "Q1", ticketUID: ticket, workspace: wsid)
        let hash = try F1Question.questionHash(qid: qid, ticketUID: ticket, text: "Which?", options: opts)
        let good = try F1Question(ticketGetQuestion(["qid": .string(qid), "hash": .string(hash)]))
        let r = try good.reviewed(ticketUID: ticket, workspace: wsid)
        #expect(r.hash == hash)
        #expect(r.qid == qid)
        // a host hash for other content, a missing hash, another workspace or another ticket: no sign sheet
        let other = "sha256:" + String(repeating: "0", count: 64)
        #expect((try? F1Question(ticketGetQuestion(["qid": .string(qid), "hash": .string(other)])).reviewed(ticketUID: ticket, workspace: wsid)) == nil)
        #expect((try? F1Question(ticketGetQuestion()).reviewed(ticketUID: ticket, workspace: wsid)) == nil)
        #expect((try? good.reviewed(ticketUID: ticket, workspace: ID16(hex: String(repeating: "1", count: 32))!)) == nil)
        #expect((try? good.reviewed(ticketUID: "01J9ZK4Q7M3R8T2V6X0B5N1C9E", workspace: wsid)) == nil)
        // a changed cost (bound) breaks it; a changed why (unbound) does not
        let costChanged = try F1Question(ticketGetQuestion(["qid": .string(qid), "hash": .string(hash),
                                                            "options": [["key": "csv", "label": "CSV", "cost": "2 days"], ["key": "api", "label": "API"]]]))
        #expect((try? costChanged.reviewed(ticketUID: ticket, workspace: wsid)) == nil)
        let whyChanged = try F1Question(ticketGetQuestion(["qid": .string(qid), "hash": .string(hash), "why": "different"]))
        #expect((try? whyChanged.reviewed(ticketUID: ticket, workspace: wsid)) != nil)
    }
}
