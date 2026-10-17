import CryptoKit
import Foundation
import OrchClient
import OrchProtocol

/// What the FakeHost serves over column R: the core's own read ops (host section 0.8; the R2 table of 11A.5), generated in the R2 answer
/// format, from one actor-owned state. The Demo owner is the one person; a device answers as that person. Persistence has the same
/// lifetime as the fake host's rid/sequence store, and no `await` separates a compare-and-set from its journal entry.
struct FakeTicket: Sendable, Equatable {
    var uid: String, key: String, title: String
    /// `ticket` or `epic`.
    var type: String
    /// A host status: `open`, `in_progress`, `done`, ...
    var status: String
    var parent: String?
    var updatedMs: Int64
    var headSeq: Int64
    var headHash: String
}

struct FakeAnswer: Sendable, Equatable {
    var atMs: Int64, seq: Int64
    var option: String?, text: String?
    var id: String
    var signerDevice: String
    var auth: String
}

struct FakeQuestion: Sendable, Equatable {
    var ticketUID: String
    /// `Q1`, `Q2`, ... on the ticket.
    var number: String
    var text: String
    var options: [F1QuestionOption]
    var blocking: Bool
    var askedMs: Int64, askedSeq: Int64
    var answer: FakeAnswer?
}

struct FakeEvent: Sendable, Equatable {
    var jpos: Int64
    var log: String           // ticket uid, or "workspace"
    var key: String?
    var uid: String?
    var title: String?
    var seq: Int64
    var type: String
    var atMs: Int64
}

package enum FakeRelayCaps: Sendable, Equatable { case absent, r6NotReady, ready }

struct HostViewState: Sendable {
    var tickets: [FakeTicket] = []
    var questions: [FakeQuestion] = []
    var events: [FakeEvent] = []
    var membersV: Int64 = 1
    var nextKeyNumber = 2
    var prefix = "MOB"
    /// Devices named only by an answer's signer (Demo seeds), with the label `member.list` gives them.
    var extraDevices: [String: String] = [:]
    /// R2 writes (`relay.submit`, SubmitAdmission.swift): the outcome store keyed `(device, idem)`, the logged phone events by id, and the
    /// Demo/test controls of the write path.
    var outcomes: [String: FakeOutcome] = [:]
    var logged: [String: FakeLogged] = [:]
    var writeControls = FakeWriteControls()
    /// B10: the requirements and plan gates of seeded tickets (by ticket uid), the open approval hints, and the test controls that make the host lie.
    var gates: [String: FakeGateSet] = [:]
    var hints: [FakeHint] = []
    var gateLies = FakeGateLies()
    /// What column-R `whoami` says about writes: `relay:{ops:{answer:1, new_ticket:1}, r6_ready}` (host changelog 57), or no field at all.
    var relayCaps = FakeRelayCaps.ready
    /// Host 11A.17 dev gate: the sandbox id (id8) while the host runs as a dev sandbox with `--dev-sim-convenience` (whoami carries
    /// `relay.dev`, `required_reader` is 1, a `convenience` answer is admitted); nil: a normal host. Toggled at runtime to emulate a restart
    /// without the flag.
    var devSimConvenience: String?
    /// Devices removed at the host (L2 standing): `not_member` for their writes.
    var removedDevices: Set<String> = []
    /// Request ids whose answer the host computed and kept but did not post (a lost response).
    var lostRids: Set<ID16> = []
    var jpos: Int64 { events.last?.jpos ?? 0 }
    var revision: Int64 { jpos }

    init(now: Int64, entropy: any Entropy) {
        tickets = [Self.ticket(entropy, now, "FAC-0001", "Demo Factory epic", type: "epic"),
                   Self.ticket(entropy, now, "MOB-0001", "Review mobile pairing", parent: "FAC-0001")]
        for t in tickets { append(type: "ticket.created", ticket: t, at: now) }
        let texts = ["Ship this change?", String(repeating: "Review every paragraph before signing.\n", count: 100),
                     "Which one: Yes or \u{FF39}es? (a full-width look-alike; F1 text carries no bidi or invisible controls)"]
        for (i, text) in texts.enumerated() {
            let options = [F1QuestionOption(key: "approve", label: i == 2 ? "Approve (full\u{FF0D}width dash)" : "Approve"),
                           F1QuestionOption(key: "reject", label: "Reject")]
            _ = ask(entropy, ticket: "MOB-0001", text: text, options: options, at: now - Int64(texts.count - i) * 1000)
        }
    }

    static func newULID(_ entropy: any Entropy, _ ms: Int64) -> String {
        (try? ULID.make(timeMs: ms, random: entropy.bytes(10))) ?? "01ARZ3NDEKTSV4RRFFQ69G5FAV"
    }

    static func ticket(_ entropy: any Entropy, _ now: Int64, _ key: String, _ title: String, type: String = "ticket", status: String = "open",
                       parent: String? = nil, at: Int64? = nil) -> FakeTicket {
        let t = at ?? now
        let uid = newULID(entropy, t)
        return FakeTicket(uid: uid, key: key, title: title, type: type, status: status, parent: parent, updatedMs: t, headSeq: 1,
                          headHash: "sha256:" + Hex.encode(SHA256.hash(data: Data((uid + "1").utf8))))
    }

    mutating func append(type: String, ticket: FakeTicket?, at: Int64) {
        let seq = ticket?.headSeq ?? Int64(events.count + 1)
        events.append(FakeEvent(jpos: jpos + 1, log: ticket?.uid ?? "workspace", key: ticket?.key, uid: ticket?.uid, title: ticket?.title, seq: seq, type: type, atMs: at))
    }

    mutating func touch(_ key: String, type: String, at: Int64) {
        guard let i = tickets.firstIndex(where: { $0.key == key }) else { return }
        tickets[i].headSeq += 1
        tickets[i].updatedMs = at
        tickets[i].headHash = "sha256:" + Hex.encode(SHA256.hash(data: Data((tickets[i].uid + String(tickets[i].headSeq)).utf8)))
        append(type: type, ticket: tickets[i], at: at)
    }

    /// Asks a new question on `ticket` (created as a stub when it does not exist yet). Returns its index.
    @discardableResult
    mutating func ask(_ entropy: any Entropy, ticket key: String, text: String, options: [F1QuestionOption], blocking: Bool = true, at: Int64) -> Int {
        if !tickets.contains(where: { $0.key == key }) {
            tickets.append(Self.ticket(entropy, at, key, key, at: at))
            append(type: "ticket.created", ticket: tickets.last, at: at)
        }
        let t = tickets.first { $0.key == key }!
        let n = questions.filter { $0.ticketUID == t.uid }.count + 1
        touch(key, type: "question.asked", at: at)
        let seq = tickets.first { $0.key == key }!.headSeq
        questions.append(FakeQuestion(ticketUID: t.uid, number: "Q\(n)", text: text, options: options, blocking: blocking, askedMs: at, askedSeq: seq, answer: nil))
        return questions.count - 1
    }
}

extension FakeHost {
    package func replaceQuestionText(_ id: ID16, text: String) throws {
        seedViews()
        guard let i = questionIndex(id) else { throw ViewError.malformed }
        viewState!.questions[i].text = text
        viewState!.touch(ticketKey(viewState!.questions[i]), type: "question.asked", at: wall.nowMs)
    }

    func seedViews() {
        if viewState == nil { viewState = HostViewState(now: wall.nowMs, entropy: entropy) }
    }

    private func ticketKey(_ q: FakeQuestion) -> String { viewState!.tickets.first { $0.uid == q.ticketUID }?.key ?? "" }

    func qid(_ q: FakeQuestion) -> String { (try? F1Question.questionID(question: q.number, ticketUID: q.ticketUID, workspace: workspace)) ?? "" }
    func hash(_ q: FakeQuestion) -> String { (try? F1Question.questionHash(qid: qid(q), ticketUID: q.ticketUID, text: q.text, options: q.options)) ?? "" }
    func questionIndex(_ id: ID16) -> Int? { viewState?.questions.firstIndex { qid($0) == id.hex } }
    func deviceLabel(_ d: ID16) -> String { core.pendingPairs[d]?.label ?? (d == primary.deviceID ? "Demo Mac" : "Demo iPhone") }

    static func time(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: Double(ms) / 1000)
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        let p = c.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", p.year!, p.month!, p.day!, p.hour!, p.minute!, p.second!)
    }

    var viewer: String { "p_" + primary.personID.hex }

    // MARK: ops

    /// The R2 read answer: the section 0.3 Result envelope around `data`.
    func result(_ data: JSONValue) -> HostReply {
        let r: JSONValue = ["data": data, "key": .null, "seq": 0, "cursor": 0, "hints": [], "lines": [], "duplicate": false, "exit": 0, "head": .null]
        guard let bytes = try? canonicalJSON(r), bytes.count <= R2.maxAnswer else { return .refuse(.host(code: "frame.too_large", retryable: false, seqs: nil, nextKey: nil)) }
        return .r2(bytes)
    }
    func hostRefusal(_ code: String) -> HostReply {
        .refuse(.host(code: code, retryable: PhoneRetryTable.classify(code, PhoneRefusalContext(eventID: "", hostNowMs: 0)).retryable, seqs: nil, nextKey: nil))
    }

    private func questionJSON(_ q: FakeQuestion) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(q.number), "state": .string(q.answer == nil ? "open" : "answered"), "to": [.string(viewer)], "blocking": .bool(q.blocking),
                                      "answered_by": q.answer == nil ? .null : .string(viewer), "answered_seq": q.answer.map { .int($0.seq) } ?? .null,
                                      "text": .string(q.text), "to_ref": .string(viewer), "asked_at": .string(Self.time(q.askedMs)),
                                      "asked_by": ["kind": "agent", "id": .null], "asked_seq": .int(q.askedSeq), "qid": .string(qid(q)), "hash": .string(hash(q))]
        if !q.options.isEmpty {
            o["options"] = .array(q.options.map { opt in
                var m: [String: JSONValue] = ["key": .string(opt.key), "label": .string(opt.label)]
                if let c = opt.cost { m["cost"] = .string(c) }
                return .object(m)
            })
        }
        if let a = q.answer {
            o["answer"] = ["by": .string(viewer), "at": .string(Self.time(a.atMs)), "seq": .int(a.seq),
                           "option": a.option.map(JSONValue.string) ?? .null, "text": a.text.map(JSONValue.string) ?? .null,
                           "id": .string(a.id), "auth": .string(a.auth), "signer": ["device": .string(a.signerDevice), "auth": .string(a.auth)]]
        }
        return .object(o)
    }

    private func snip(_ text: String) -> (String, Bool) {
        guard text.utf8.count > 1024 else { return (text, false) }
        var bytes = Array(text.utf8.prefix(1024))
        while !bytes.isEmpty, String(validatingUTF8: bytes.map { CChar(bitPattern: $0) } + [0]) == nil { bytes.removeLast() }
        return (String(decoding: bytes, as: UTF8.self), true)
    }

    private func read(_ op: String, args: [String: JSONValue], device: ID16, scopes: [String]) -> HostReply {
        let s = viewState!
        let cursor: JSONValue = .string("j:\(s.jpos)")
        let asOf: JSONValue = .string(Self.time(wall.nowMs))
        switch op {
        case "whoami":
            var who: [String: JSONValue] = ["peer": ["uid": -1, "class": "person"], "person": .string(viewer), "tier": "A", "grant": .null, "session": .null]
            switch s.relayCaps {
            case .absent: break
            case .r6NotReady: who["relay"] = ["ops": ["answer": 1, "approve": 1, "changes": 1, "new_ticket": 1], "r6_ready": false]
            case .ready: who["relay"] = ["ops": ["answer": 1, "approve": 1, "changes": 1, "new_ticket": 1], "r6_ready": true]
            }
            if let id8 = s.devSimConvenience, var relay = who["relay"]?.object {
                relay["dev"] = ["sim_convenience": true, "sandbox": .string(id8)]
                who["relay"] = .object(relay)
            }
            return result(.object(who))
        case "workspace.show":
            return result(["id": .string(workspace.hex), "prefix": .string(s.prefix), "name": .string(name), "genesis": .string("sha256:" + String(repeating: "0", count: 64)),
                           "epoch": .int(Int64(epoch)), "wsk_fingerprint": "demo", "members_v": .int(s.membersV), "state": "ok",
                           "next_key": scopes.contains("decide") ? .string(s.prefix + "-" + String(format: "%04d", s.nextKeyNumber)) : .null,
                           "required_reader": .int(s.devSimConvenience == nil ? 0 : 1)])
        case "member.list":
            var devices: [JSONValue] = []
            for d in core.members.keys.sorted(by: { $0.hex < $1.hex }) {
                devices.append(["id": .string("d_" + d.hex), "auth": .null, "scopes": .array((core.members[d] ?? []).map(JSONValue.string)), "valid": true,
                                "label": .string(deviceLabel(d)), "paired_at": .null, "relay": true, "cert_expires_at": .null, "reader": .null])
            }
            for (id, label) in s.extraDevices.sorted(by: { $0.key < $1.key }) {
                devices.append(["id": .string(id), "auth": .null, "scopes": ["look", "decide"], "valid": true, "label": .string(label), "paired_at": .null,
                                "relay": false, "cert_expires_at": .null, "reader": .null])
            }
            return result(["members": [["person": .string(viewer), "name": "Demo owner", "role": "owner", "devices": .array(devices)]], "required_reader": .int(s.devSimConvenience == nil ? 0 : 1)])
        case "needs":
            var items: [JSONValue] = []
            for q in s.questions where q.answer == nil {
                guard let t = s.tickets.first(where: { $0.uid == q.ticketUID }) else { continue }
                let (text, cut) = snip(q.text)
                let payload: [String: JSONValue] = ["question": .string(q.number), "blocking": .bool(q.blocking), "to": .string(viewer),
                                                    "options": .array(q.options.map { ["key": .string($0.key), "label": .string($0.label)] })]
                var item: [String: JSONValue] = ["kind": "question", "key": .string(t.key), "uid": .string(t.uid), "ref": .string(q.number),
                                                 "detail": .string(q.blocking ? "blocking" : ""), "who": [.string(viewer)], "since": .string(Self.time(q.askedMs)),
                                                 "text": .string(text), "status": .string(t.status), "payload": .object(payload)]
                if cut { item["text_cut"] = true }
                items.append(.object(item))
            }
            return result(["items": .array(items), "sub_cursor": cursor])
        case "ticket.query":
            var rows = s.tickets.filter { $0.status != "closed" }
            if let st = args["status"]?.array?.compactMap(\.string), !st.isEmpty { rows = s.tickets.filter { st.contains($0.status) } }
            rows.sort { $0.updatedMs != $1.updatedMs ? $0.updatedMs > $1.updatedMs : $0.key < $1.key }
            let limit = Int(args["limit"]?.int ?? 50)
            let offset: Int
            if let page = args["page"]?.string {
                guard page.hasPrefix("o:"), let n = Int(page.dropFirst(2)), n >= 0 else { return hostRefusal("page.expired") }
                offset = n
            } else { offset = 0 }
            let slice = Array(rows.dropFirst(offset).prefix(limit))
            let more = offset + slice.count < rows.count
            let json: [JSONValue] = slice.map { t in
                let epic = t.parent.flatMap { p in s.tickets.first { $0.key == p && $0.type == "epic" }?.key }
                return ["key": .string(t.key), "uid": .string(t.uid), "title": .string(t.title), "type": .string(t.type), "status": .string(t.status), "priority": .null,
                        "size": .null, "labels": [], "assignees": [], "owner": .string(viewer), "parent": t.parent.map(JSONValue.string) ?? .null,
                        "epic": epic.map(JSONValue.string) ?? .null, "claim": .null, "gates": [:], "needs": [], "updated_at": .string(Self.time(t.updatedMs)),
                        "head_seq": .int(t.headSeq),
                        "blocking_questions": .int(Int64(s.questions.filter { $0.ticketUID == t.uid && $0.answer == nil && $0.blocking }.count))]
            }
            return result(["rows": .array(json), "next_page": more ? .string("o:\(offset + slice.count)") : .null, "total": .int(Int64(rows.count)),
                           "sub_cursor": cursor, "as_of": asOf])
        case "ticket.get":
            guard let ref = args["ref"]?.string, let t = s.tickets.first(where: { $0.key == ref || $0.uid == ref }) else { return hostRefusal("not_found") }
            var docFields: [String: JSONValue] = ["uid": .string(t.uid), "key": .string(t.key), "title": .string(t.title), "type": .string(t.type), "status": .string(t.status),
                                                  "owner": .string(viewer), "head": ["seq": .int(t.headSeq), "head": .string(t.headHash)]]
            if let g = s.gates[t.uid] { docFields["sections"] = .object(gateSectionTexts(g).mapValues(JSONValue.string)) }
            let doc = JSONValue.object(docFields)
            let qs = s.questions.filter { $0.ticketUID == t.uid }.map(questionJSON)
            return result(["doc": doc, "log": [], "log_more": false, "questions": .array(qs), "criteria": [], "gates": gatesJSON(t.uid), "sub_cursor": cursor,
                           "status": .string(t.status), "settled": .bool(t.status == "done" || t.status == "closed"), "members_v": .int(s.membersV)])
        case "activity.list":
            var items = s.events.reversed().filter { e in
                if let types = args["types"]?.array?.compactMap(\.string), !types.isEmpty { return types.contains(e.type) }
                return true
            }
            let limit = Int(args["limit"]?.int ?? 50)
            items = Array(items.prefix(limit))
            let json: [JSONValue] = items.map { e in
                ["id": .string("ev" + String(e.jpos)), "jpos": .int(e.jpos), "log": .string(e.log), "key": e.key.map(JSONValue.string) ?? .null,
                 "uid": e.uid.map(JSONValue.string) ?? .null, "title": e.title.map(JSONValue.string) ?? .null, "seq": .int(e.seq), "ws_seq": .int(e.seq),
                 "type": .string(e.type), "at": .string(Self.time(e.atMs)), "actor": ["kind": "agent", "id": .null], "summary": "", "data": [:]]
            }
            return result(["items": .array(json), "next_page": .null, "sub_cursor": cursor, "as_of": asOf])
        case "reader.declare":
            // H12d-3 (a read on column R): the host stores the declaration and answers `{device, reader, level, digest}`
            guard let v = args["reader_decl"], let d = try? ReaderDeclaration(signed: v) else { return hostRefusal("reader.decl_invalid") }
            return result(["device": .string("d_" + device.hex), "reader": .int(Int64(d.level)), "level": .int(Int64(d.level)), "digest": .string(d.digest)])
        case "phone.requests": return phoneRequestsReply(scopes: scopes)
        case "gate.input": return gateInputReply(args: args)
        case "workspace.settings": return result(["settings": [:]])
        default: return hostRefusal("not_found")
        }
    }

    func handleView(_ req: HostRequest) -> HostReply {
        seedViews()
        guard let m = req.meta.object, let op = m["op"]?.string else { return .refuse(.malformed) }
        func reply(_ v: JSONValue, _ status: Int = 200) -> HostReply {
            .response(status: status, headers: ["content-type": "application/json"], data: (try? canonicalJSON(v)) ?? Data())
        }
        switch op {
        case "http":
            guard req.data.isEmpty else { return .refuse(.malformed) }
            // not an R2 op: the closed table has no `http`; kept only as the bridge tests' vehicle (a plain 404)
            return reply(["host_api": 0, "error": "not_found"], 404)
        case "answer", "new_ticket", "approve", "changes":
            // the FakeHost's OWN shape check of a write's meta (never only the client's): {op, args{...}, idem, rd?}, no data
            guard Set(m.keys).isSubset(of: ["op", "args", "idem", "rd"]), m["args"]?.object != nil, m["idem"]?.string != nil, req.data.isEmpty
            else { return hostRefusal("invalid.input") }
            fallthrough
        default:
            // an R2 request: the host's own meta checks first, then the closed table's scope, then the op
            let checked: (op: String, spec: R2.OpSpec, args: [String: JSONValue], idem: String?, rd: String?)
            do { checked = try R2.checkMeta(req.meta, data: req.data) }
            catch let e as R2.MetaError { return e == .forbiddenScope ? .refuse(.forbiddenScope) : hostRefusal(e.code) }
            catch { return .refuse(.malformed) }
            guard req.scopes.contains(checked.spec.scope) else { return .refuse(.forbiddenScope) }
            if checked.spec.kind == .write {
                // `answer` and `new_ticket` (SubmitAdmission.swift)
                guard ["answer", "new_ticket", "approve", "changes"].contains(checked.op) else { return hostRefusal("op.not_allowed") }
                return submitWrite(req, op: checked.op, args: checked.args, idem: checked.idem)
            }
            if checked.op == "outcome.get" {
                guard let idem = checked.args["idem"]?.string, ULID.isValid(idem) else { return hostRefusal("invalid.input") }
                return outcomeGet(req, idem: idem)
            }
            return read(checked.op, args: checked.args, device: req.device, scopes: req.scopes)
        }
    }

    func label(ofSigner device: String) -> String {
        if let d = ID16(hex: String(device.dropFirst(2))), core.members[d] != nil || d == primary.deviceID { return deviceLabel(d) }
        return viewState?.extraDevices[device] ?? "Unknown device"
    }
}
