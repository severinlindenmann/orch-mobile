import CryptoKit
import Foundation
import OrchClient
import OrchProtocol

/// Demo-only controls of the fake host, for the app's Demo panels and Demo content (never a path to a real workspace: a `FakeHost` exists
/// only inside a Demo environment). Everything here acts as the HOST (what a person does at the Mac); the phone's own signing and
/// reading paths are untouched.
public struct DemoOptionSeed: Sendable, Equatable {
    public let id: String, label: String
    public init(_ id: String, _ label: String) { self.id = id; self.label = label }
}
public struct DemoQuestionSeed: Sendable, Equatable {
    public struct Answer: Sendable, Equatable {
        public let optionID: String, byLabel: String, agoMs: Int64
        public init(optionID: String, byLabel: String, agoMs: Int64) { self.optionID = optionID; self.byLabel = byLabel; self.agoMs = agoMs }
    }
    public let ticket: String, text: String
    public let options: [DemoOptionSeed]
    public let createdAgoMs: Int64
    public let answer: Answer?
    public init(ticket: String, text: String, options: [DemoOptionSeed], createdAgoMs: Int64, answer: Answer? = nil) {
        self.ticket = ticket; self.text = text; self.options = options; self.createdAgoMs = createdAgoMs; self.answer = answer
    }
}
public struct DemoTicketSeed: Sendable, Equatable {
    public let key: String, title: String, body: String, state: String, kind: String, epicKey: String?, updatedAgoMs: Int64
    public init(key: String, title: String, body: String, state: String = "open", kind: String = "ticket", epicKey: String? = nil, updatedAgoMs: Int64 = 60_000) {
        self.key = key; self.title = title; self.body = body; self.state = state; self.kind = kind; self.epicKey = epicKey; self.updatedAgoMs = updatedAgoMs
    }
}

extension FakeHost {
    private func demoViews() -> HostViewState {
        if viewState == nil { viewState = HostViewState(now: wall.nowMs, entropy: entropy) }
        return viewState!
    }

    private func questionJSON(_ s: DemoQuestionSeed, id: ID16, now: Int64) throws -> JSONValue {
        let options: JSONValue = .array(s.options.map { ["id": .string($0.id), "label": .string($0.label)] })
        let hash = try Decisions.questionHash(questionID: id, ticket: s.ticket, text: s.text, options: options)
        var q: [String: JSONValue] = ["question_id": .string(id.hex), "ticket": .string(s.ticket), "text": .string(s.text), "options": options,
                                      "content_hash": .string(B64U.encode(hash)), "created_ms": .int(now - s.createdAgoMs), "state": "open", "resolution": .null]
        if let a = s.answer {
            q["state"] = "closed"
            q["resolution"] = ["decision_id": .string(entropy.id16().hex), "answer": ["option_id": .string(a.optionID)],
                               "by_device_id": .string(primary.deviceID.hex), "by_device_label": .string(a.byLabel), "at_ms": .int(now - a.agoMs)]
        }
        return .object(q)
    }

    /// Replaces the host's questions and tickets with the given Demo content. Returns the question ids in order.
    @discardableResult
    public func demoSeedViews(questions: [DemoQuestionSeed], tickets: [DemoTicketSeed]) throws -> [ID16] {
        var state = demoViews()
        let now = wall.nowMs
        var ids: [ID16] = []
        state.questions = try questions.map { s in
            let id = entropy.id16(); ids.append(id)
            return try questionJSON(s, id: id, now: now)
        }
        state.tickets = tickets.map { t in
            ["key": .string(t.key), "title": .string(t.title), "body": .string(t.body), "state": .string(t.state), "kind": .string(t.kind),
             "epic_key": t.epicKey.map(JSONValue.string) ?? .null, "updated_ms": .int(now - t.updatedAgoMs)]
        }
        state.revision += 1
        viewState = state
        return ids
    }

    /// The host asks a new question (the phone sees it on its next read).
    @discardableResult
    public func demoAskQuestion(_ seed: DemoQuestionSeed) throws -> ID16 {
        var state = demoViews()
        let id = entropy.id16()
        state.questions.append(try questionJSON(seed, id: id, now: wall.nowMs))
        state.revision += 1
        viewState = state
        return id
    }

    /// A person answers at the Mac first: the question closes with this resolution, so the phone's later answer is `already_answered`.
    public func demoAnswerOnHost(question id: ID16, optionID: String, byLabel: String = "Demo Mac") throws {
        var state = demoViews()
        guard let i = state.questions.firstIndex(where: { $0.object?["question_id"]?.string == id.hex }), var q = state.questions[i].object,
              q["resolution"] == .null,
              q["options"]?.array?.contains(where: { $0.object?["id"]?.string == optionID }) == true else { throw ViewError.malformed }
        q["state"] = "closed"
        q["resolution"] = ["decision_id": .string(entropy.id16().hex), "answer": ["option_id": .string(optionID)],
                           "by_device_id": .string(primary.deviceID.hex), "by_device_label": .string(byLabel), "at_ms": .int(wall.nowMs)]
        state.questions[i] = .object(q)
        state.revision += 1
        viewState = state
    }

    /// The text of an open question changes at the host (its content hash changes with it, so a signed answer to the old text is refused).
    public func demoEditQuestion(_ id: ID16, text: String) throws { try replaceQuestionText(id, text: text) }

    /// Seals a section 9 push for this workspace as the host would, in the exact bytes the relay forwards. Demo notifications only.
    public func demoSealPush(kind: String, id: String, label: String) throws -> Data {
        let e = max(epoch, 1)
        let p: JSONValue = ["kind": .string(kind), "id": .string(id), "label": .string(label), "ts_ms": .int(wall.nowMs)]
        let signed = Data(Label.sigPush.utf8) + Bytes.u8(Suite2.id) + workspace.bytes + Bytes.u32(e) + (try canonicalJSON(p))
        let sig = try wsk.rawSignature(over: signed)
        let inner = try canonicalJSON(["p": p, "sig": .string(B64U.encode(sig))])
        let aad = Data(Label.aadPush.utf8) + Bytes.u8(Suite2.id) + workspace.bytes + Bytes.u32(e)
        let c = try SaltedAEAD.seal(key: KDF.kPush(wk: wk(e), workspace: workspace, epoch: e), msgLabel: Label.kdfPushMsg, aad: aad, plaintext: inner)
        return try canonicalJSON(["v": 2, "ws": .string(workspace.hex), "epoch": .int(Int64(e)), "c": .string(B64U.encode(c))])
    }

    /// What the phone would hold in its push group for this workspace: `K_push` per epoch (derived; never `WK`).
    public func demoPushKeys() -> (epoch: UInt32, kPush: Data) {
        let e = max(epoch, 1)
        return (e, KDF.kPush(wk: wk(e), workspace: workspace, epoch: e).withUnsafeBytes { Data($0) })
    }
}

extension FakeHost {
    private func clearHandler() { handler = nil }

    /// The next view read the phone makes is refused once (a read that fails to load).
    public func demoFailNextRead() {
        handler = { [weak self] _ in
            await self?.clearHandler()
            return .refuse(.malformed)
        }
    }

    /// The host applies the next decision it receives but the response is lost on its way back (the phone's outcome is `uncertain`).
    public func demoLoseNextDecisionResponse(faults: ScriptedFaults) {
        handler = { [weak self] req in
            guard let self else { return .refuse(.malformed) }
            let reply = await self.handleView(req)
            if req.meta.object?["op"] == "decision" {
                faults.enqueue(.disconnect, at: .pollDelivery)
                await self.clearHandler()
            }
            return reply
        }
    }
}
