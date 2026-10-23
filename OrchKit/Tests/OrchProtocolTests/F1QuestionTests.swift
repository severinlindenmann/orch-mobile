import Foundation
import Testing
@testable import OrchProtocol

/// The phone's question protocol (design #1123 rev 4): the raw-question hash over verbatim `options` and `spec`, the closed parser, the
/// pinned fold and the answer rules, against the FROZEN orch-core fixtures (`f1/hashes.json`, `f1/questions.json`, `f1/phone_events.json`;
/// PROVENANCE.md says which are shared with the relay and the dashboard).
@Suite struct F1QuestionTests {
    let hashes = F1Vectors.load("hashes")
    let questions = F1Vectors.load("questions")
    let labels = F1Vectors.load("labels")
    let base = "sha256:" + String(repeating: "b", count: 64)
    let wsid = ID16(hex: "0123456789abcdef0123456789abcdef")!
    let ticket = "01J9ZK4Q7M3R8T2V6X0B5N1C9D"

    /// `spec` as core computes it from a raw question: every key except `id`, `to`, `blocking`, `text`, `options`.
    func specOf(_ raw: JSONValue) -> JSONValue {
        .object((raw.object ?? [:]).filter { !["id", "to", "blocking", "text", "options"].contains($0.key) })
    }
    func content(_ raw: JSONValue) throws -> F1Question.Content {
        try F1Question.Content(text: raw.object?["text"], options: raw.object?["options"], spec: specOf(raw))
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

    // MARK: hash vectors [shared with core, hub, dashboard]

    @Test func questionHashKnownAnswers() throws {
        let cases = hashes["question_hash"].items
        #expect(cases.count == 29)
        for c in cases {
            let raw = c["question"], name = c["name"].str
            // the phone hashes `options` and `spec` as given: here, the vector's own `hashed` object
            let hashed = c["hashed"]
            #expect(hashed["options"] == .array(raw.object?["options"]?.array ?? []), "\(name) options verbatim")
            #expect(hashed["spec"] == specOf(raw), "\(name) spec is the complement")
            let got = try F1Question.questionHash(qid: c["qid"].str, ticketUID: c["ticket"].str, text: hashed["text"],
                                                  options: raw.object?["options"], spec: hashed["spec"])
            #expect(got == c["hash"].str, "\(name)")
        }
    }

    /// Re-asks that change only routing (`to`, `blocking`) keep the hash: an answer stands.
    @Test func routingOnlyVariantsHaveTheSameHash() {
        let same = hashes["question_hash"].items.filter { $0.object?["same_as"] != nil }
        #expect(same.count == 2)
        for c in same { #expect(c["hash"].str == hashes["question_hash"].items.first { $0["name"].str == c["same_as"].str }?["hash"].str) }
    }

    /// Core refuses every one of these. The phone sees only text, options and spec (routing keys are the view's), so a question
    /// that breaks only a routing rule is not a content refusal here; `missing_blocking` is the one such vector.
    @Test func refusedQuestionShapesDoNotParse() {
        let routingOnly: Set<String> = ["missing_blocking"]
        let cases = hashes["question_hash_refused"].items
        #expect(cases.count == 69)
        for c in cases {
            let name = c["name"].str
            guard c["question"].object != nil else { continue }              // "not_an_object": nothing to read
            if routingOnly.contains(name) { #expect((try? content(c["question"])) != nil, "\(name)"); continue }
            #expect((try? content(c["question"])) == nil, "\(name) must not parse")
        }
    }

    @Test func foldVectorsAreThePinnedUnicode16Table() {
        let cases = hashes["question_fold"].items
        #expect(cases.count == 11)
        for c in cases { #expect(F1Text.fold(c["text"].str).utf8.elementsEqual(c["folded"].str.utf8), "\(c["text"].str.unicodeScalars.map(\.value))") }
    }

    @Test func blankSetIsUnicodeWhiteSpace() {
        let cases = hashes["question_blank"].items
        #expect(cases.count == 9)
        for c in cases { #expect(F1Text.isBlank(c["text"].str) == (c["blank"].bool ?? false), "\(c["text"].str.unicodeScalars.map(\.value))") }
    }

    @Test func answerRulesPerKind() throws {
        let cases = hashes["question_answers"].items
        #expect(cases.count == 20)
        for c in cases {
            let name = c["name"].str
            let content = try content(c["question"])
            var threw = false
            do { try content.checkAnswer(option: c["option"].string, text: c["text"].string) } catch { threw = true }
            #expect(threw == !(c["ok"].bool ?? false), "\(name)")
        }
    }

    // MARK: the three forms of one question [shared]

    @Test func eachFormHashesToTheSameValue() throws {
        let forms = questions["forms"].items
        #expect(forms.map { $0["name"].str } == ["choice_full", "text_with_why_and_details"])
        for f in forms {
            let name = f["name"].str, uid = f["ticket"].str
            // raw event: the question as signed and replayed
            let ev = f["raw_event"], raw = ev["question"]
            let qid = try F1Question.questionID(question: raw["id"].str, ticketUID: uid, workspace: wsid)
            #expect(qid == ev["qid"].str, "\(name) qid")
            let fromRaw = try F1Question.questionHash(qid: qid, ticketUID: uid, content: content(raw))
            #expect(fromRaw == ev["hash"].str, "\(name) raw_event")
            // read item: options and spec verbatim, no top-level why/recommended/kind
            let item = try F1Question(f["read_item"])
            let (rq, rh) = try item.verified(ticketUID: uid, workspace: wsid)
            #expect(rq == qid && rh == ev["hash"].str, "\(name) read_item")
            #expect(item.kind.rawValue == raw["kind"].str)
            // hub needs: the content carries text, options and spec; the row carries the hash
            let needs = f["hub_needs"], row = needs["row"], c = needs["content"]
            let fromNeeds = try F1Question.questionHash(qid: row["item_id"].str, ticketUID: row["log"].str, text: c["text"], options: c.object?["options"], spec: c["spec"])
            #expect(fromNeeds == row["hash"].str && fromNeeds == ev["hash"].str, "\(name) hub_needs")
        }
    }

    // MARK: parser

    /// The `choice_full` read item of the frozen fixtures, edited.
    func item(_ edit: (inout [String: JSONValue]) -> Void = { _ in }, form: Int = 0) -> JSONValue {
        var q = questions["forms"].items[form]["read_item"].object!
        edit(&q)
        return .object(q)
    }
    func optionsEdit(_ f: @escaping (inout [JSONValue]) -> Void) -> (inout [String: JSONValue]) -> Void {
        { q in var o = q["options"]!.array!; f(&o); q["options"] = .array(o) }
    }
    func option(_ i: Int, _ edit: @escaping (inout [String: JSONValue]) -> Void) -> (inout [String: JSONValue]) -> Void {
        optionsEdit { o in var x = o[i].object!; edit(&x); o[i] = .object(x) }
    }
    func specEdit(_ f: @escaping (inout [String: JSONValue]) -> Void) -> (inout [String: JSONValue]) -> Void {
        { q in var s = q["spec"]!.object!; f(&s); q["spec"] = .object(s) }
    }
    func refusal(_ v: JSONValue) -> F1QuestionRefusal? {
        do { _ = try F1Question(v); return nil } catch { return error as? F1QuestionRefusal }
    }

    @Test func parsesTheFullChoiceQuestion() throws {
        let q = try F1Question(item())
        #expect(q.id == "Q1" && q.state == .open && q.kind == .choice)
        #expect(q.text.hasPrefix("Which export should feed"))
        #expect(q.options.map(\.key) == ["csv", "api", "other"])
        #expect(q.options[0].label == "Monthly CSV" && q.options[0].text == "One file a month, checked by hand")
        #expect(q.options[0].facts == [F1Fact(label: "Effort", value: "\u{BD} day"), F1Fact(label: "Cost", value: "CHF 400")])
        #expect(q.options[0].cost == "\u{BD} day" && q.options[2].cost == nil && q.options[2].facts.isEmpty)
        #expect(q.why == "The seeds are stale." && q.recommended == "csv" && q.allowOther)
        #expect(q.details == "If you pick CSV, we import monthly.\n\tAPI means a daily pull.")
        #expect(q.answer == nil)
    }

    @Test func parsesATextQuestion() throws {
        let q = try F1Question(item(form: 1))
        #expect(q.kind == .text && q.options.isEmpty && q.recommended == nil && !q.allowOther)
        #expect(q.why == "For the invoice." && q.details == "IBAN or name is fine.")
        // a text question has no options: absent is the only "none"
        #expect(refusal(item({ $0["options"] = [] }, form: 1))?.code == .option)
    }

    @Test func oneEncodingOneRendering() {
        #expect(refusal(item(option(0) { $0["facts"] = [] }))?.code == .facts)               // empty facts
        #expect(refusal(item(option(0) { $0["facts"] = ["Effort": "1 day"] }))?.code == .facts)   // object form
        #expect(refusal(item(option(0) { $0["facts"] = [["A", "1", "x"]] }))?.code == .facts)
        #expect(refusal(item(option(0) { $0["facts"] = [["A", "1"], ["B", "2"], ["C", "3"], ["D", "4"]] }))?.code == .facts)
        #expect(refusal(item(option(0) { $0["facts"] = [["Cost", "1"], ["COST", "2"]] }))?.code == .facts)    // duplicate label after fold
        #expect(refusal(item(option(0) { $0["text"] = "" }))?.code == .option)
        #expect(refusal(item(option(0) { $0["cost"] = "" }))?.code == .option)
        #expect(refusal(item(specEdit { $0["why"] = "" }))?.code == .spec)
        #expect(refusal(item(specEdit { $0["details"] = "" }))?.code == .spec)
        #expect(refusal(item(specEdit { $0["allow_other"] = false }))?.code == .spec)
        #expect(refusal(item(specEdit { $0["allow_other"] = .null }))?.code == .spec)
    }

    @Test func unknownKindOrKeyIsCannotVerifyWithAReason() {
        let kind = refusal(item(specEdit { $0["kind"] = "date" }))
        #expect(kind?.code == .unknownKind && !(kind?.reason.isEmpty ?? true))
        #expect(refusal(item(specEdit { $0["kind"] = .null }))?.code == .unknownKind)
        #expect(refusal(item(specEdit { $0["kind"] = nil }))?.code == .unknownKind)
        #expect(refusal(item(specEdit { $0["value"] = "x" }))?.code == .unknownKey)
        #expect(refusal(item(option(0) { $0["value"] = "x" }))?.code == .unknownKey)
        // a key of another kind: `recommended` and `allow_other` belong to choice only
        #expect(refusal(item(specEdit { $0["recommended"] = "csv" }, form: 1))?.code == .unknownKey)
    }

    /// A reason is shown to the person: it never carries host text (a key, a kind, a title, a fact label).
    @Test func reasonsNeverEchoHostText() {
        let hostile = ["evil\u{202E}key", "line\nbreak", String(repeating: "k", count: 500), "<b>bold</b>", "[click](http://x)", "Cancel \u{2014} tap OK"]
        for h in hostile {
            let reasons = [
                refusal(item(specEdit { $0[h] = "x" }))?.reason,
                refusal(item(specEdit { $0["kind"] = .string(h) }))?.reason,
                refusal(item(option(0) { $0[h] = "x" }))?.reason,
                refusal(item(option(0) { $0["key"] = .string(h) }))?.reason,
                refusal(item(option(0) { $0["label"] = .string(h + "\u{200B}") }))?.reason,
                refusal(item(option(0) { $0["facts"] = [[.string(h), "v"], [.string(h), "w"]] }))?.reason,
                refusal(item(specEdit { $0["recommended"] = .string(h) }))?.reason,
            ]
            for r in reasons {
                #expect(r != nil && !(r ?? "").isEmpty)
                let r = r ?? ""
                #expect(!r.contains(h) && !r.contains("\u{202E}") && !r.contains("\n") && !r.contains("<b>") && r.count < 120, "\(r)")
            }
        }
    }

    @Test func oldShapeIsGone() {
        // no spec (the option-only shape): cannot verify, no fallback
        #expect(refusal(item({ $0["spec"] = nil }))?.code == .malformed)
        #expect((try? F1Question(item({ $0["spec"] = nil; $0["options"] = [["key": "a", "label": "A"], ["key": "b", "label": "B"]] }))) == nil)
        // top-level why/recommended/kind are not content: ignored, never read as the question's own
        let q = try? F1Question(item({ $0["why"] = "tampered"; $0["recommended"] = "api"; $0["kind"] = "text" }))
        #expect(q?.why == "The seeds are stale." && q?.recommended == "csv" && q?.kind == .choice)
    }

    @Test func limitsAndTextRulesAreEnforced() {
        #expect(refusal(item { $0["text"] = .string(String(repeating: "q", count: 141)) })?.code == .text)
        #expect(refusal(item { $0["text"] = "cafe\u{301}?" })?.code == .text)
        #expect(refusal(item { $0["text"] = "Pick\u{200B}one" })?.code == .text)
        #expect(refusal(item(option(0) { $0["label"] = "Monthly\nCSV" }))?.code == .option)
        #expect(refusal(item(option(0) { $0["label"] = .string(String(repeating: "T", count: 61)) }))?.code == .option)
        #expect(refusal(item(option(0) { $0["key"] = "CSV" }))?.code == .option)
        #expect(refusal(item(optionsEdit { $0 = Array($0.prefix(1)) }))?.code == .option)
        #expect(refusal(item(optionsEdit { $0 += [["key": "d", "label": "D"], ["key": "e", "label": "E"], ["key": "f", "label": "F"], ["key": "g", "label": "G"]] }))?.code == .option)
        #expect(refusal(item(option(1) { $0["key"] = "csv" }))?.code == .option)                        // duplicate key
        #expect(refusal(item(option(1) { $0["label"] = "MONTHLY csv" }))?.code == .option)               // same title after fold
        #expect(refusal(item(option(1) { $0["label"] = "Monthly CSV" }))?.code == .option)
        #expect(refusal(item(specEdit { $0["recommended"] = "pdf" }))?.code == .spec)
        #expect(refusal(item(specEdit { $0["details"] = .string(String(repeating: "d", count: 1501)) }))?.code == .spec)
        #expect(refusal(item(specEdit { $0["details"] = .string(String(repeating: "\u{20AC}", count: 1400)) }))?.code == .spec)   // 4200 bytes
        // title uniqueness uses the pinned fold: sharp s against SS, capital sharp s against ss, Kelvin against k
        func titles(_ a: String, _ b: String) -> JSONValue { item(chain(optionsEdit { $0 = [["key": "a", "label": .string(a)], ["key": "b", "label": .string(b)]] }, specEdit { $0["recommended"] = nil; $0["allow_other"] = nil })) }
        for (a, b) in [("Stra\u{DF}e", "STRASSE"), ("\u{1E9E}", "ss"), ("\u{212A}elvin", "kelvin"), ("\u{FB01}le", "FILE"), ("\u{130}stanbul", "i\u{307}stanbul")] {
            #expect(refusal(titles(a, b))?.code == .option, "\(a) / \(b)")
        }
        #expect(refusal(titles("Yes", "No")) == nil)
    }

    @Test func unknownTopLevelKeysAreIgnoredAtQuestionAnswerAndSignerLevel() throws {
        // host section 0.4: clients ignore unknown keys the host sends; every known key is still validated
        #expect((try? F1Question(item { $0["surprise"] = 1 })) != nil)
        var a = answered().object!["answer"]!.object!
        a["extra_answer_key"] = "x"
        var signer = a["signer"]!.object!
        signer["extra_signer_key"] = 1
        a["signer"] = .object(signer)
        let q = try F1Question(item { $0["state"] = "answered"; $0["answered_by"] = "p_75bf75a3bb50b0c4ac02f8a757b90e23"; $0["answered_seq"] = 3; $0["answer"] = .object(a) })
        #expect(q.answer?.signerAuth == .secureEnclaveUnlocked)
        #expect((try? F1Question(item { $0["surprise"] = 1; $0["blocking"] = "yes" })) == nil)
    }

    @Test func refusesMissingKeyAndBadTypes() {
        #expect((try? F1Question(item { $0["blocking"] = nil })) == nil)
        #expect(refusal(item { $0["text"] = nil })?.code == .text)        // a missing text is "cannot verify" with a reason
        #expect((try? F1Question(item { $0["id"] = "Q01" })) == nil)
        #expect((try? F1Question(item { $0["state"] = "closed" })) == nil)
        #expect((try? F1Question(item { $0["to"] = ["sev"] })) == nil)
        #expect((try? F1Question(item { $0["qid"] = "xyz" })) == nil)
    }

    func answered(auth: JSONValue = "secure-enclave-unlocked", signerAuth: JSONValue = "secure-enclave-unlocked") -> JSONValue {
        let answer: JSONValue = ["by": "p_75bf75a3bb50b0c4ac02f8a757b90e23", "at": "2026-10-10T10:01:10Z", "seq": 3, "option": "csv", "text": .null,
                                 "auth": auth, "id": "01M4JM4RKG79RG3QTWCP60NNNG",
                                 "signer": ["device": "d_762df76def3afcc7bfc48dbc595f8add", "auth": signerAuth]]
        return item { $0["state"] = "answered"; $0["answered_by"] = "p_75bf75a3bb50b0c4ac02f8a757b90e23"; $0["answered_seq"] = 3; $0["answer"] = answer }
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
        #expect((try? F1Question(item { $0["state"] = "answered" })) == nil)
        let a = answered().object!["answer"]!
        #expect((try? F1Question(item { $0["answer"] = a })) == nil)
    }

    @Test func answerNeedsOptionOrText() {
        let a: JSONValue = ["by": "p_75bf75a3bb50b0c4ac02f8a757b90e23", "at": "t", "seq": 3, "option": .null, "text": .null, "id": "01M4JM4RKG79RG3QTWCP60NNNG"]
        #expect((try? F1Question(item { $0["state"] = "answered"; $0["answer"] = a })) == nil)
    }

    // MARK: verified (recomputed qid and hash)

    @Test func verifiedRecomputesAndComparesToTheHost() throws {
        let good = try F1Question(item())
        let r = try good.verified(ticketUID: ticket, workspace: wsid)
        #expect(r.hash == good.hash && r.qid == good.qid)
        // another workspace or another ticket: no sign sheet
        #expect((try? good.verified(ticketUID: ticket, workspace: ID16(hex: String(repeating: "1", count: 32))!)) == nil)
        #expect((try? good.verified(ticketUID: "01J9ZK4Q7M3R8T2V6X0B5N1C9E", workspace: wsid)) == nil)
        // a missing hash, or a hash for other content
        #expect((try? F1Question(item { $0["hash"] = nil }).verified(ticketUID: ticket, workspace: wsid)) == nil)
        let other: JSONValue = .string("sha256:" + String(repeating: "0", count: 64))
        #expect((try? F1Question(item { $0["hash"] = other }).verified(ticketUID: ticket, workspace: wsid)) == nil)
        // a text question verifies too
        _ = try F1Question(item(form: 1)).verified(ticketUID: ticket, workspace: wsid)
    }

    /// Every bound field changes the hash (the tamper variants of the oracle): a host cannot change a fact, a title, the order, the
    /// recommendation, the reason, the details, `allow_other` or the kind under the hash it already sent.
    @Test func everyBoundFieldBreaksTheHostHash() {
        func cannotVerify(_ v: JSONValue) -> Bool {
            guard let q = try? F1Question(v) else { return true }       // refused outright is also not answerable
            do { _ = try q.verified(ticketUID: ticket, workspace: wsid); return false } catch let e as F1QuestionRefusal { return e.code == .hashMismatch } catch { return false }
        }
        #expect(!cannotVerify(item()))
        #expect(cannotVerify(item { $0["text"] = "Which export should feed the tariff tables?" }))
        #expect(cannotVerify(item(specEdit { $0["why"] = "The seeds are old." })))
        #expect(cannotVerify(item(specEdit { $0["why"] = nil })))
        #expect(cannotVerify(item(specEdit { $0["details"] = "If you pick CSV, we import weekly." })))
        #expect(cannotVerify(item(specEdit { $0["recommended"] = "api" })))
        #expect(cannotVerify(item(specEdit { $0["allow_other"] = nil })))
        #expect(cannotVerify(item(option(0) { $0["label"] = "Monthly CSV file" })))
        #expect(cannotVerify(item(option(0) { $0["text"] = "One file a month" })))
        #expect(cannotVerify(item(option(0) { $0["cost"] = "1 day" })))
        #expect(cannotVerify(item(option(0) { $0["facts"] = [["Effort", "\u{BD} day"], ["Cost", "CHF 500"]] })))
        #expect(cannotVerify(item(option(0) { $0["facts"] = [["Effort", "\u{BD} day"], ["Price", "CHF 400"]] })))
        #expect(cannotVerify(item(option(0) { $0["facts"] = [["Cost", "CHF 400"], ["Effort", "\u{BD} day"]] })))
        #expect(cannotVerify(item(option(0) { $0["facts"] = nil })))
        #expect(cannotVerify(item(optionsEdit { $0.reverse() })))
        #expect(cannotVerify(item(chain(specEdit { $0["kind"] = "text" }, { $0["options"] = nil }))))
    }
}

/// Applies `a`, then `b`, to one question object (test helper).
func chain(_ a: @escaping (inout [String: JSONValue]) -> Void, _ b: @escaping (inout [String: JSONValue]) -> Void) -> (inout [String: JSONValue]) -> Void {
    { q in a(&q); b(&q) }
}
