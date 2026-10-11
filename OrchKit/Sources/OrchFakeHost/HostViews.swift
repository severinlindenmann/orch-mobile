import Foundation
import OrchClient
import OrchProtocol

/// Actor-owned fake persistence, with the same lifetime as the fake host's rid/sequence store.
/// No await separates compare-and-set, revision increment and receipt recording.
struct HostViewState: Sendable {
    var revision: Int64 = 1
    var questions: [JSONValue]
    var tickets: [JSONValue]
    var creations: [String: (request: Data, ticket: JSONValue)] = [:]
    init(now: Int64, entropy: any Entropy) {
        tickets = [Self.ticket("FAC-1", "Factory", "Demo Factory epic", now, kind: "factory_epic"),
                   Self.ticket("MOB-1", "Review mobile pairing", "Compare both codes.", now, epic: "FAC-1")]
        questions = ["Ship this change?", String(repeating: "Review every paragraph before signing.\n", count: 100),
                     "Inspect bidi: \u{202E}abc\u{202C} and invisible \u{200B} text."].enumerated().map { i, text in
            let id = entropy.id16()
            let options: JSONValue = [["id": "approve", "label": .string(i == 2 ? "Approve\u{2066} safely\u{2069}" : "Approve")],
                                      ["id": "reject", "label": "Reject"]]
            let hash = try! Decisions.questionHash(questionID: id, ticket: "MOB-1", text: text, options: options)
            return ["question_id": .string(id.hex), "ticket": "MOB-1", "text": .string(text), "options": options,
                    "content_hash": .string(B64U.encode(hash)), "created_ms": .int(now), "state": "open", "resolution": .null]
        }
    }
    static func ticket(_ key: String, _ title: String, _ body: String, _ now: Int64, kind: String = "ticket", epic: String? = nil) -> JSONValue {
        ["key": .string(key), "title": .string(title), "body": .string(body), "state": "open", "kind": .string(kind),
         "epic_key": epic.map(JSONValue.string) ?? .null, "updated_ms": .int(now)]
    }
}

extension FakeHost {
    package func replaceQuestionText(_ id: ID16, text: String) throws {
        seedViews()
        guard let i = viewState!.questions.firstIndex(where: { $0.object?["question_id"]?.string == id.hex }),
              var q = viewState!.questions[i].object else { throw ViewError.malformed }
        q["text"] = .string(text)
        q["content_hash"] = .string(B64U.encode(try Decisions.questionHash(questionID: id, ticket: q["ticket"]!.string!, text: text, options: q["options"]!)))
        viewState!.questions[i] = .object(q); viewState!.revision += 1
    }
    private func seedViews() { if viewState == nil { viewState = HostViewState(now: wall.nowMs, entropy: entropy) } }
    func handleView(_ req: HostRequest) -> HostReply {
        seedViews()
        guard req.data.isEmpty, let m = req.meta.object else { return .refuse(.malformed) }
        func reply(_ v: JSONValue, _ status: Int = 200) -> HostReply {
            .response(status: status, headers: ["content-type": "application/json"], data: (try? canonicalJSON(v)) ?? Data())
        }
        func missing() -> HostReply { reply(["host_api": 0, "error": "not_found"], 404) }
        switch m["op"]?.string {
        case "http":
            guard m.exactly(["op", "method", "path", "headers"]), m["method"] == "GET", m["headers"]?.object?.isEmpty == true,
                  let path = m["path"]?.string else { return .refuse(.malformed) }
            if path == "/v2/snapshot" {
                let members: [JSONValue] = core.members.keys.sorted { $0.hex < $1.hex }.map {
                    ["device_id": .string($0.hex), "label": .string(core.pendingPairs[$0]?.label ?? ($0 == primary.deviceID ? "Demo Mac" : "Demo iPhone"))]
                }
                return reply(["host_api": 0, "workspace_id": .string(workspace.hex), "revision": .int(viewState!.revision),
                              "checked_ms": .int(wall.nowMs), "questions": .array(viewState!.questions), "tickets": .array(viewState!.tickets), "members": .array(members)])
            }
            let qprefix = "/v2/questions/", tprefix = "/v2/tickets/"
            if path.hasPrefix(qprefix), let id = ID16(hex: String(path.dropFirst(qprefix.count))) {
                guard let q = viewState!.questions.first(where: { $0.object?["question_id"]?.string == id.hex }) else { return missing() }
                return reply(["host_api": 0, "workspace_id": .string(workspace.hex), "question": q])
            }
            if path.hasPrefix(tprefix), validTicketKey(String(path.dropFirst(tprefix.count))) {
                guard let t = viewState!.tickets.first(where: { $0.object?["key"]?.string == String(path.dropFirst(tprefix.count)) }) else { return missing() }
                return reply(["host_api": 0, "workspace_id": .string(workspace.hex), "ticket": t])
            }
            return .refuse(.malformed)
        case "decision":
            guard let key = core.devicePubs[req.device] else { return .refuse(.badSignature) }
            do { try Decisions.verifyOp(req.meta, workspace: workspace, deviceKey: key) }
            catch Refusal.malformed { return .refuse(.malformed) }
            catch { return .refuse(.badSignature) }
            guard let i = viewState!.questions.firstIndex(where: { $0.object?["question_id"] == m["question_id"] }),
                  var q = viewState!.questions[i].object else { return missing() }
            if let resolution = q["resolution"]?.object {
                if resolution["decision_id"] == m["decision_id"], resolution["answer"] == m["answer"] {
                    return reply(["host_api": 0, "decision_id": m["decision_id"]!, "question": .object(q)])
                }
                return .refuse(.alreadyAnswered(byDeviceLabel: resolution["by_device_label"]!.string!, atMs: resolution["at_ms"]!.int!))
            }
            guard q["content_hash"] == m["content_hash"] else { return .refuse(.questionChanged(contentHash: B64U.decode(q["content_hash"]!.string!)!)) }
            guard let answer = m["answer"]?.object, answer.exactly(["option_id"]), let option = answer["option_id"]?.string,
                  q["options"]!.array!.contains(where: { $0.object?["id"]?.string?.utf8Equal(option) == true }) else { return .refuse(.malformed) }
            q["state"] = "closed"
            q["resolution"] = ["decision_id": m["decision_id"]!, "answer": m["answer"]!, "by_device_id": .string(req.device.hex),
                               "by_device_label": .string(core.pendingPairs[req.device]?.label ?? "Demo iPhone"), "at_ms": .int(wall.nowMs)]
            viewState!.questions[i] = .object(q); viewState!.revision += 1
            return reply(["host_api": 0, "decision_id": m["decision_id"]!, "question": .object(q)])
        case "new_ticket":
            guard m.exactly(["op", "host_api", "creation_id", "title", "body", "epic_key"]) else { return .refuse(.malformed) }
            guard m["host_api"] == 0 else { return reply(["host_api": 0, "error": "unsupported_host_api"], 400) }
            guard let id = m.idField("creation_id"), let title = m["title"]?.string, let body = m["body"]?.string,
                  m["epic_key"] == .null || m["epic_key"]?.string != nil else { return .refuse(.malformed) }
            let draft = NewTicketSubmission(creationID: id, title: title, body: body, epicKey: m["epic_key"]?.string)
            guard (try? draft.validate()) != nil, let bytes = try? canonicalJSON(req.meta) else { return .refuse(.malformed) }
            let receiptID = req.device.hex + ":" + id.hex
            if let old = viewState!.creations[receiptID] {
                guard old.request == bytes else { return reply(["host_api": 0, "error": "creation_conflict"], 409) }
                return reply(["host_api": 0, "creation_id": .string(id.hex), "ticket": old.ticket], 201)
            }
            if let epic = draft.epicKey, !viewState!.tickets.contains(where: { $0.object?["key"]?.string == epic && $0.object?["kind"] == "factory_epic" }) { return .refuse(.malformed) }
            let ticket = HostViewState.ticket("MOB-\(viewState!.tickets.count)", title, body, wall.nowMs, epic: draft.epicKey)
            viewState!.tickets.append(ticket); viewState!.revision += 1
            viewState!.creations[receiptID] = (bytes, ticket)
            return reply(["host_api": 0, "creation_id": .string(id.hex), "ticket": ticket], 201)
        default: return .refuse(.malformed)
        }
    }
}
