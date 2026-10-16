import CryptoKit
import Foundation
import OrchClient
import OrchProtocol

/// The FakeHost's `relay.submit` for `answer` and `new_ticket` (host section 11A.14 14.6), written from the spec tables and independent of the phone's own
/// checks: it never calls `PhoneEvents.validateSigned` or `R2.writeMeta`, and recomputes the signing bytes from the formula itself, so a
/// fault shared by the client's validator cannot make both sides pass. Order: P1, P2, P3, P4, P5, P7 before the lock; then L1, L2, L3, W,
/// L4, L5, L6, L7, L8, L9, for `answer` and `new_ticket` alike.

/// One record of the outcome store, keyed `(device, idem)`. `binding` is `cj(event - sig)`: the same idem with other content is
/// `idem.conflict`.
struct FakeOutcome: Sendable, Equatable {
    enum State: String, Sendable { case pending, committed, failed }
    var state: State
    let binding: Data
    let log: String
    let idemMs: Int64
    /// committed: the landed seq. failed: the refusal code (and `seqs` for a failure after a landing; never for "not run").
    var seq: Int64?
    var code: String?
    /// failed `ticket.key_not_next`: the advisory next key (`error.detail.next_key`).
    var nextKey: String?
    /// The event as planned (L7): what `recover()` appends when the host crashed after planning.
    let event: [String: JSONValue]
    let device: String
}

/// A phone event in the log: its content identity (digest of the signing bytes) and actor, for L3 dedup.
struct FakeLogged: Sendable, Equatable {
    let log: String, digest: String, actor: JSONValue, seq: Int64
}

/// Demo and test controls of the write path. Each is one-shot.
struct FakeWriteControls: Sendable, Equatable {
    /// The host plans the write (outcome `pending`) and stops before the append: no answer.
    var crashAfterPlan = false
    /// The host appends the event and stops before recording the outcome: no answer.
    var crashAfterAppend = false
    /// The host runs the write and keeps its answer, but the answer is not posted (a lost response).
    var loseNextResponse = false
    /// The host holds the next write admitted and not run (`pending`) until `recoverWrites`.
    var holdNext = false
}

extension FakeHost {
    static let ticketEventLabel = "orch/v2/sig/ticket-event|"
    static let unknownIdemBoundMs: Int64 = 1_200_000
    static let windowPastMs: Int64 = 900_000
    static let windowFutureMs: Int64 = 300_000

    private var ownerPerson: String { "p_" + primary.personID.hex }

    private func refusal(_ code: String, seqs: [Int64]? = nil, nextKey: String? = nil) -> HostReply {
        // `retryable` is derived from the class (amendment C); written out here per code, not computed by the phone's classifier
        let retryable = ["pending", "already_done", "idem.expired", "busy", "store.busy", "lock.busy"].contains(code)
        return .refuse(.host(code: code, retryable: retryable, seqs: seqs, nextKey: code == "ticket.key_not_next" ? nextKey : nil))
    }

    private func writeResult(log: String, seq: Int64, key: String?, duplicate: Bool) -> HostReply {
        let r: JSONValue = ["data": ["log": .string(log), "seqs": [.int(seq)]], "key": key.map(JSONValue.string) ?? .null, "seq": .int(seq), "cursor": 0,
                            "hints": [], "lines": [], "duplicate": .bool(duplicate), "exit": 0, "head": .null]
        return .r2((try? canonicalJSON(r)) ?? Data())
    }

    private static func ulidMs(_ id: String) -> Int64? {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)
        let u = Array(id.utf8)
        guard u.count == 26, let f = u.first, f >= 0x30, f <= 0x37 else { return nil }
        var v: Int64 = 0
        for c in u.prefix(10) { guard let i = alphabet.firstIndex(of: c) else { return nil }; v = (v << 5) | Int64(i) }
        for c in u.dropFirst(10) where !alphabet.contains(c) { return nil }
        return v
    }

    /// `relay.submit` for one `answer` or `new_ticket` request. `args` and `idem` come from the host's own meta check (`R2.checkMeta`).
    func submitWrite(_ req: HostRequest, op: String, args: [String: JSONValue], idem: String?) -> HostReply {
        let device = "d_" + req.device.hex
        // P1: {"log": uid, "events": [exactly one]}, idem == events[0].id
        guard Set(args.keys) == ["log", "events"], let log = args["log"]?.string, let events = args["events"]?.array, events.count == 1,
              let ev = events[0].object else { return refusal("validation.event") }
        guard let id = ev["id"]?.string, let idem, Data(idem.utf8) == Data(id.utf8) else { return refusal("invalid.input") }
        // P2: the op's one event type
        let creation = op == "new_ticket"
        guard ev["type"]?.string == (creation ? "ticket.created" : "question.answered") else { return refusal("forbidden_scope") }
        // P3: the submitted subset, exactly
        let host: Set<String> = ["seq", "at", "prev", "ws_seq", "host_sig"]
        guard Set(ev.keys).isDisjoint(with: host) else { return refusal("validation.event") }
        let common: Set<String> = ["v", "hash_v", "id", "type", "actor", "auth", "roster_v", "based_on", "sig"]
        let keys = Set(ev.keys)
        guard ev["v"]?.int == 2, ev["hash_v"]?.int == 1, Self.ulidMs(id) != nil, Self.ulidMs(log) != nil,
              let roster = ev["roster_v"]?.int, roster >= 0 else { return refusal("validation.event") }
        var shape: (base: String, qn: String, hash: String)?
        var created: (key: String, type: String, title: String, owner: String)?
        if creation {
            // a creation: exactly key, ticket_type, title, owner; based_on null; the key's shape; one of the five types; a one-line title
            guard keys == common.union(["key", "ticket_type", "title", "owner"]), ev["based_on"] == .null,
                  let key = ev["key"]?.string, Self.isKey(key), let type = ev["ticket_type"]?.string,
                  ["feature", "bug", "chore", "spike", "epic"].contains(type), let owner = ev["owner"]?.string,
                  let title = ev["title"]?.string else { return refusal("validation.event") }
            let n = title.unicodeScalars.count
            guard n >= 1, n <= 200, F1Text.isClean(title, oneLine: true) else { return refusal("validation.text") }
            created = (key, type, title, owner)
        } else {
            let required = common.union(["question", "hash"])
            guard keys.isSuperset(of: required), keys.isSubset(of: required.union(["option", "text"])), ev["option"] != nil || ev["text"] != nil,
                  let base = ev["based_on"]?.string, let qn = ev["question"]?.string, let hash = ev["hash"]?.string else { return refusal("validation.event") }
            if let o = ev["option"] { guard let s = o.string, !s.isEmpty, F1Text.isClean(s, oneLine: true) else { return refusal("validation.text") } }
            if let t = ev["text"] { guard let s = t.string, !s.isEmpty, F1Text.isClean(s) else { return refusal("validation.text") } }
            shape = (base, qn, hash)
        }
        // P4: actor = {person, the device's person, the device}; sig present
        guard let a = ev["actor"]?.object, Set(a.keys) == ["kind", "id", "device"], a["kind"]?.string == "person",
              a["id"]?.string == ownerPerson, a["device"]?.string == device, let sigText = ev["sig"]?.string else { return refusal("op.not_allowed") }
        // P5: `convenience` is never admitted here (the FakeHost has no dev gate; a creation never takes it at all)
        guard let auth = ev["auth"]?.string, ["secure-enclave-unlocked", "passphrase"].contains(auth) else { return refusal("op.not_allowed") }
        // P7: the signature over the recomputed person signing bytes
        var unsigned = ev; unsigned["sig"] = nil
        guard let pub = core.devicePubs[req.device], let sig = B64U.decode(sigText, length: 64),
              let body = try? canonicalJSON(["contract": 1, "event": .object(unsigned), "log": .string(log), "suite": 2, "workspace_id": .string(workspace.hex)])
        else { return refusal("sig.invalid") }
        let signing = Data(Self.ticketEventLabel.utf8) + body
        guard Signature.verify(pub, signature: sig, label: Self.ticketEventLabel, message: body) else { return refusal("sig.invalid") }
        let digest = "sha256:" + Hex.encode(SHA256.hash(data: signing))
        guard let binding = try? canonicalJSON(.object(unsigned)) else { return refusal("validation.event") }
        // L1: the actor-owned state is the fresh state. L2: standing and scopes again.
        guard core.members[req.device] != nil, !core.revoked.contains(req.device), !viewState!.removedDevices.contains(device) else { return refusal("not_member") }
        guard (core.members[req.device] ?? []).contains("decide") else { return refusal("forbidden_scope") }
        // L3: the outcome store by (device, idem) first (amendment A), then the log by (log, id) with digest and actor
        let okey = device + "|" + id
        if let o = viewState!.outcomes[okey] {
            guard o.binding == binding else { return refusal("idem.conflict") }
            switch o.state {
            case .pending: return refusal("pending")
            case .committed: return writeResult(log: o.log, seq: o.seq ?? 0, key: ticketKey(uid: o.log), duplicate: true)
            case .failed: return refusal(o.code ?? "internal", seqs: o.seq.map { [$0] }, nextKey: o.nextKey)
            }
        }
        if let l = viewState!.logged[id] {
            guard l.log == log, l.digest == digest, l.actor == ev["actor"] else { return refusal("event.duplicate_id") }
            return writeResult(log: log, seq: l.seq, key: ticketKey(uid: log), duplicate: true)
        }
        // W: a never-seen event only
        let now = wall.nowMs
        let t = Self.ulidMs(id)!
        guard t >= now - Self.windowPastMs, t <= now + Self.windowFutureMs else { return record(okey, binding, log, t, ev, device, failed: "event.expired") }
        let target: WriteTarget
        if let created { target = .creation(key: created.key, type: created.type, title: created.title, owner: created.owner) }
        else if let shape { target = .answer(base: shape.base, qn: shape.qn, hash: shape.hash) }
        else { return refusal("validation.event") }
        return admit(okey: okey, binding: binding, log: log, idMs: t, event: ev, device: device, digest: digest, roster: roster, target: target)
    }

    /// The host's `Key` shape (`[A-Z][A-Z0-9]{1,9}-[0-9]{4,}`), written here again (never the phone's parser).
    static func isKey(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let p = parts.first, let n = parts.last, (2...10).contains(p.utf8.count), (4...12).contains(n.utf8.count),
              let f = p.utf8.first, f >= 0x41, f <= 0x5A else { return false }
        return p.utf8.allSatisfy { ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39) } && n.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    /// The store's next key (L5), computed at job time from the FakeHost state.
    var nextKey: String { viewState!.prefix + "-" + String(format: "%04d", viewState!.nextKeyNumber) }

    private func ticketKey(uid: String) -> String? { viewState?.tickets.first { $0.uid == uid }?.key }

    private func record(_ okey: String, _ binding: Data, _ log: String, _ t: Int64, _ ev: [String: JSONValue], _ device: String, failed code: String,
                        nextKey: String? = nil) -> HostReply {
        viewState!.outcomes[okey] = FakeOutcome(state: .failed, binding: binding, log: log, idemMs: t, seq: nil, code: code, nextKey: nextKey, event: ev, device: device)
        return refusal(code, nextKey: nextKey)
    }

    /// What a write targets: an answer's question, or a creation's new ticket.
    enum WriteTarget {
        case answer(base: String, qn: String, hash: String)
        case creation(key: String, type: String, title: String, owner: String)
    }

    /// L4 to L6 for either type (also run again by `recoverWrites`): nil when admitted, else the refusal code and, for a key race, the
    /// advisory next key.
    private func check(log: String, roster: Int64, target: WriteTarget, option: String?) -> (code: String, nextKey: String?)? {
        let s = viewState!
        switch target {
        case .answer(let base, let qn, let hash):
            // L4: the ticket exists and the person may see it (uniform not_found)
            guard let ticket = s.tickets.first(where: { $0.uid == log }) else { return ("not_found", nil) }
            // L6: the model's judgement at the position
            return judge(ticket: ticket, roster: roster, base: base, qn: qn, hash: hash, option: option).map { ($0, nil) }
        case .creation(let key, _, _, let owner):
            // L4: the uid is unused
            guard !s.tickets.contains(where: { $0.uid == log }) else { return ("ticket.exists", nil) }
            // L5: the owner is the signer's person; the key is exactly the store's next key (a race carries the advisory next key)
            guard owner == ownerPerson else { return ("invalid.input", nil) }
            guard key == nextKey else { return ("ticket.key_not_next", nextKey) }
            // L6: the model's judgement (the roster at the position)
            guard roster == s.membersV else { return ("members.stale", nil) }
            return nil
        }
    }

    /// L4 to L9 for an event that passed L3 and W.
    private func admit(okey: String, binding: Data, log: String, idMs: Int64, event ev: [String: JSONValue], device: String, digest: String,
                       roster: Int64, target: WriteTarget) -> HostReply {
        if let refused = check(log: log, roster: roster, target: target, option: ev["option"]?.string) {
            return record(okey, binding, log, idMs, ev, device, failed: refused.code, nextKey: refused.nextKey)
        }
        // L7: plan, persisted as pending
        viewState!.outcomes[okey] = FakeOutcome(state: .pending, binding: binding, log: log, idemMs: idMs, seq: nil, code: nil, nextKey: nil, event: ev, device: device)
        if viewState!.writeControls.crashAfterPlan || viewState!.writeControls.holdNext {
            viewState!.writeControls.crashAfterPlan = false; viewState!.writeControls.holdNext = false
            return .refuse(.alreadyDone(status: "unknown"))
        }
        // L8: append
        let seq = append(log: log, event: ev, digest: digest, device: device)
        if viewState!.writeControls.crashAfterAppend {
            viewState!.writeControls.crashAfterAppend = false
            return .refuse(.alreadyDone(status: "unknown"))
        }
        // L9: the log shows the event: committed
        viewState!.outcomes[okey]!.state = .committed
        viewState!.outcomes[okey]!.seq = seq
        return writeResult(log: log, seq: seq, key: ticketKey(uid: log), duplicate: false)
    }

    private func judge(ticket: FakeTicket, roster: Int64, base: String, qn: String, hash: String, option: String?) -> String? {
        let s = viewState!
        let history = (1...max(ticket.headSeq, 1)).map { "sha256:" + Hex.encode(SHA256.hash(data: Data((ticket.uid + String($0)).utf8))) }
        guard history.contains(base) else { return "event.bad_base" }
        guard roster == s.membersV else { return "members.stale" }
        guard let q = s.questions.first(where: { $0.ticketUID == ticket.uid && $0.number == qn }) else { return "question.unknown" }
        // spec L6 order: base, roster, hash, open, option
        guard self.hash(q) == hash else { return "question.stale" }
        guard q.answer == nil else { return "question.answered" }
        if let option { guard q.options.contains(where: { Data($0.key.utf8) == Data(option.utf8) }) else { return "answer.bad_option" } }
        return nil
    }

    /// Appends the event and logs its identity: an answer closes its question; a creation makes the ticket (its log's first event, seq 1)
    /// and takes the next key. Returns its seq.
    private func append(log: String, event ev: [String: JSONValue], digest: String, device: String) -> Int64 {
        let now = wall.nowMs
        if ev["type"]?.string == "ticket.created" {
            let key = ev["key"]?.string ?? ""
            let t = FakeTicket(uid: log, key: key, title: ev["title"]?.string ?? "", type: ev["ticket_type"]?.string ?? "feature", status: "open",
                               parent: nil, updatedMs: now, headSeq: 1, headHash: "sha256:" + Hex.encode(SHA256.hash(data: Data((log + "1").utf8))))
            viewState!.tickets.append(t)
            viewState!.append(type: "ticket.created", ticket: t, at: now)
            if let n = Int(key.split(separator: "-").last ?? ""), n >= viewState!.nextKeyNumber { viewState!.nextKeyNumber = n + 1 }
            viewState!.logged[ev["id"]?.string ?? ""] = FakeLogged(log: log, digest: digest, actor: ev["actor"] ?? .null, seq: 1)
            return 1
        }
        guard let ticket = viewState!.tickets.first(where: { $0.uid == log }) else { return 0 }
        viewState!.touch(ticket.key, type: "question.answered", at: now)
        let seq = viewState!.tickets.first { $0.uid == ticket.uid }!.headSeq
        if let i = viewState!.questions.firstIndex(where: { $0.ticketUID == ticket.uid && $0.number == ev["question"]?.string }) {
            viewState!.questions[i].answer = FakeAnswer(atMs: now, seq: seq, option: ev["option"]?.string, text: ev["text"]?.string,
                                                        id: ev["id"]?.string ?? "", signerDevice: device, auth: ev["auth"]?.string ?? "")
        }
        viewState!.logged[ev["id"]?.string ?? ""] = FakeLogged(log: ticket.uid, digest: digest, actor: ev["actor"] ?? .null, seq: seq)
        return seq
    }

    /// `outcome.get {idem}` for this device: the record, or `pending` with no record until the ULID time + 1 200 s, then `unknown_idem`.
    func outcomeGet(_ req: HostRequest, idem: String) -> HostReply {
        let okey = "d_" + req.device.hex + "|" + idem
        let data: JSONValue
        if let o = viewState!.outcomes[okey] {
            switch o.state {
            case .pending: data = ["state": "pending"]
            case .committed:
                let result: JSONValue = ["data": ["log": .string(o.log), "seqs": [.int(o.seq ?? 0)]], "key": ticketKey(uid: o.log).map(JSONValue.string) ?? .null,
                                         "seq": .int(o.seq ?? 0), "cursor": 0, "hints": [], "lines": [], "duplicate": false, "exit": 0, "head": .null]
                data = ["state": "committed", "exit": 0, "error": .null, "result": result]
            case .failed:
                var err: [String: JSONValue] = ["code": .string(o.code ?? "internal")]
                if let k = o.nextKey { err["detail"] = ["next_key": .string(k)] }
                var d: [String: JSONValue] = ["state": "failed", "exit": 3, "error": .object(err)]
                if let seq = o.seq { d["seqs"] = [.int(seq)] }
                data = .object(d)
            }
        } else {
            guard let t = Self.ulidMs(idem) else { return refusal("invalid.input") }
            guard wall.nowMs >= t + Self.unknownIdemBoundMs else {
                return .r2((try? canonicalJSON(["data": ["state": "pending"], "key": .null, "seq": 0, "cursor": 0, "hints": [], "lines": [],
                                                "duplicate": false, "exit": 0, "head": .null])) ?? Data())
            }
            return .refuse(.host(code: "outcome.unknown_idem", retryable: false, seqs: nil, nextKey: nil))
        }
        let r: JSONValue = ["data": data, "key": .null, "seq": 0, "cursor": 0, "hints": [], "lines": [], "duplicate": false, "exit": 0, "head": .null]
        return .r2((try? canonicalJSON(r)) ?? Data())
    }

    // MARK: crash reconciliation and controls

    /// FakeHost restart (`relay.submit.recover`): a pending record whose event the log holds becomes `committed`; a pending one that did
    /// not land runs again from L2 (standing rechecked; the window applies: a recovered submission after it is `event.expired`).
    package func recoverWrites() {
        seedViews()
        for (okey, o) in viewState!.outcomes where o.state == .pending {
            let id = o.event["id"]?.string ?? ""
            if let l = viewState!.logged[id] {
                viewState!.outcomes[okey]!.state = .committed; viewState!.outcomes[okey]!.seq = l.seq
                continue
            }
            guard let dev = ID16(hex: String(o.device.dropFirst(2))), core.members[dev] != nil, !core.revoked.contains(dev),
                  !viewState!.removedDevices.contains(o.device) else { viewState!.outcomes[okey]!.state = .failed; viewState!.outcomes[okey]!.code = "not_member"; continue }
            guard (core.members[dev] ?? []).contains("decide") else { viewState!.outcomes[okey]!.state = .failed; viewState!.outcomes[okey]!.code = "forbidden_scope"; continue }
            let now = wall.nowMs
            guard o.idemMs >= now - Self.windowPastMs, o.idemMs <= now + Self.windowFutureMs else {
                viewState!.outcomes[okey]!.state = .failed; viewState!.outcomes[okey]!.code = "event.expired"; continue
            }
            let target: WriteTarget
            if o.event["type"]?.string == "ticket.created" {
                target = .creation(key: o.event["key"]?.string ?? "", type: o.event["ticket_type"]?.string ?? "", title: o.event["title"]?.string ?? "",
                                   owner: o.event["owner"]?.string ?? "")
            } else {
                target = .answer(base: o.event["based_on"]?.string ?? "", qn: o.event["question"]?.string ?? "", hash: o.event["hash"]?.string ?? "")
            }
            if let refused = check(log: o.log, roster: o.event["roster_v"]?.int ?? -1, target: target, option: o.event["option"]?.string) {
                viewState!.outcomes[okey]!.state = .failed; viewState!.outcomes[okey]!.code = refused.code
                viewState!.outcomes[okey]!.nextKey = refused.nextKey; continue
            }
            var unsigned = o.event; unsigned["sig"] = nil
            let body = (try? canonicalJSON(["contract": 1, "event": .object(unsigned), "log": .string(o.log), "suite": 2, "workspace_id": .string(workspace.hex)])) ?? Data()
            let digest = "sha256:" + Hex.encode(SHA256.hash(data: Data(Self.ticketEventLabel.utf8) + body))
            let seq = append(log: o.log, event: o.event, digest: digest, device: o.device)
            viewState!.outcomes[okey]!.state = .committed; viewState!.outcomes[okey]!.seq = seq
        }
    }

    package func setWriteControls(crashAfterPlan: Bool = false, crashAfterAppend: Bool = false, loseNextResponse: Bool = false, holdNext: Bool = false) {
        seedViews()
        viewState!.writeControls = FakeWriteControls(crashAfterPlan: crashAfterPlan, crashAfterAppend: crashAfterAppend,
                                                     loseNextResponse: loseNextResponse, holdNext: holdNext)
    }

    /// The member list moves on (`members_v` + 1): an answer signed under the old `roster_v` is `members.stale` (C-auto).
    public func demoBumpMembersV() { seedViews(); viewState!.membersV += 1 }
    /// Someone else (the Mac) creates a ticket: the next key moves on, so a creation signed with the old one is `ticket.key_not_next`.
    public func demoTakeNextKey() {
        seedViews()
        let now = wall.nowMs
        let t = HostViewState.ticket(entropy, now, nextKey, "Created on the Mac")
        viewState!.nextKeyNumber += 1
        viewState!.tickets.append(t)
        viewState!.append(type: "ticket.created", ticket: t, at: now)
    }
    /// The host holds the next write admitted and not run (`pending`) until `demoRecoverWrites`.
    public func demoHoldNextWrite() { seedViews(); viewState!.writeControls.holdNext = true }
    public func demoRecoverWrites() { recoverWrites() }
    /// The host runs the next write but its answer is lost on the way back: the phone settles with `outcome.get`.
    public func demoLoseNextWriteResponse() { seedViews(); viewState!.writeControls.loseNextResponse = true }
    /// The host removes a device (L2: its later writes are `not_member`).
    public func demoRemoveDevice(_ d: ID16) { seedViews(); viewState!.removedDevices.insert("d_" + d.hex) }

    /// Tests: the stored outcome of `(device, idem)`.
    package func outcomeRecord(device: ID16, idem: String) -> (state: String, code: String?, seq: Int64?)? {
        viewState?.outcomes["d_" + device.hex + "|" + idem].map { ($0.state.rawValue, $0.code, $0.seq) }
    }
    /// Tests: how many phone events the log holds.
    package func loggedCount() -> Int { viewState?.logged.count ?? 0 }
}
