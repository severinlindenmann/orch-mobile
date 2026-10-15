import CryptoKit
import Foundation
import OrchClient
import OrchProtocol

/// Demo-only controls of the fake host, for the app's Demo panels and Demo content (never a path to a real workspace: a `FakeHost` exists
/// only inside a Demo environment). Everything here acts as the HOST (what a person does at the Mac); the phone's own signing and
/// reading paths are untouched.
public struct DemoOptionSeed: Sendable, Equatable {
    public let id: String, label: String, cost: String?
    public init(_ id: String, _ label: String, cost: String? = nil) { self.id = id; self.label = label; self.cost = cost }
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
        seedViews()
        return viewState!
    }

    private func f1Options(_ s: DemoQuestionSeed) -> [F1QuestionOption] { s.options.map { F1QuestionOption(key: $0.id, label: $0.label, cost: $0.cost) } }

    /// Asks `seed` on its ticket and, for an answered seed, records the answer as a device-signed `question.answered` (by the Mac).
    private func apply(_ seed: DemoQuestionSeed, to state: inout HostViewState, now: Int64) -> ID16 {
        let at = now - seed.createdAgoMs
        let i = state.ask(entropy, ticket: seed.ticket, text: seed.text, options: f1Options(seed), at: at)
        if let a = seed.answer {
            let when = now - a.agoMs
            let device: String
            if a.byLabel == "Demo Mac" { device = "d_" + primary.deviceID.hex }
            else if a.byLabel == "Demo iPhone", let d = core.members.keys.first(where: { $0 != primary.deviceID }) { device = "d_" + d.hex }
            else {
                device = "d_" + entropy.id16().hex
                state.extraDevices[device] = a.byLabel
            }
            let key = state.tickets.first { $0.uid == state.questions[i].ticketUID }!.key
            state.touch(key, type: "question.answered", at: when)
            let seq = state.tickets.first { $0.key == key }!.headSeq
            state.questions[i].answer = FakeAnswer(atMs: when, seq: seq, option: a.optionID, text: nil, id: HostViewState.newULID(entropy, when),
                                                   signerDevice: device, auth: "secure-enclave-unlocked")
        }
        return ID16(hex: (try? F1Question.questionID(question: state.questions[i].number, ticketUID: state.questions[i].ticketUID, workspace: workspace)) ?? "") ?? ID16.random()
    }

    /// Replaces the host's questions and tickets with the given Demo content. Returns the question ids (their `qid`s) in order.
    @discardableResult
    public func demoSeedViews(questions: [DemoQuestionSeed], tickets: [DemoTicketSeed]) throws -> [ID16] {
        var state = demoViews()
        let now = wall.nowMs
        state.tickets = []; state.questions = []; state.extraDevices = [:]
        for t in tickets {
            let type = t.kind == "factory_epic" ? "epic" : "ticket"
            let made = HostViewState.ticket(entropy, now, t.key, t.title, type: type, status: t.state, parent: t.epicKey, at: now - t.updatedAgoMs)
            state.tickets.append(made)
            state.append(type: "ticket.created", ticket: made, at: now - t.updatedAgoMs)
        }
        var ids: [ID16] = []
        for q in questions { ids.append(apply(q, to: &state, now: now)) }
        if let n = state.tickets.compactMap({ Int($0.key.split(separator: "-").last ?? "") }).max() { state.nextKeyNumber = n + 1 }
        viewState = state
        return ids
    }

    /// The host asks a new question (the phone sees it on its next read).
    @discardableResult
    public func demoAskQuestion(_ seed: DemoQuestionSeed) throws -> ID16 {
        var state = demoViews()
        let id = apply(seed, to: &state, now: wall.nowMs)
        viewState = state
        return id
    }

    /// A person answers at the Mac first: the question closes with this resolution, so the phone's later answer is `already_answered`.
    public func demoAnswerOnHost(question id: ID16, optionID: String, byLabel: String = "Demo Mac") throws {
        var state = demoViews()
        guard let i = questionIndex(id), state.questions[i].answer == nil,
              state.questions[i].options.contains(where: { $0.key == optionID }) else { throw ViewError.malformed }
        let now = wall.nowMs
        let device: String
        if byLabel == "Demo Mac" { device = "d_" + primary.deviceID.hex } else {
            device = "d_" + entropy.id16().hex
            state.extraDevices[device] = byLabel
        }
        let key = state.tickets.first { $0.uid == state.questions[i].ticketUID }!.key
        state.touch(key, type: "question.answered", at: now)
        let seq = state.tickets.first { $0.key == key }!.headSeq
        state.questions[i].answer = FakeAnswer(atMs: now, seq: seq, option: optionID, text: nil, id: HostViewState.newULID(entropy, now),
                                               signerDevice: device, auth: "secure-enclave-unlocked")
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
}
