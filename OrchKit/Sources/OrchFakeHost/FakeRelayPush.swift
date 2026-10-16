import Foundation
import OrchClient
import OrchProtocol

/// The push registration routes of the fake relay (P3-D40, protocol-v2 section 19.10), device-authenticated. With `pushEnabled` off both
/// answer 404 `not_found`, before authentication, exactly like a relay without push configured. The host's send route is not modelled.
extension FakeRelay {
    public static let pushTopic = "io.severin.orch"

    /// Tests: every registration of `device` as `(workspace, env, registration id, token)`.
    public func pushRegistrations(device: ID16) -> [(workspace: ID16, env: String, id: ID16, token: String)] {
        pushRegs.filter { $0.key.device == device }.map { ($0.key.workspace, $0.key.env, $0.value.id, $0.value.token) }
    }

    public var pushRegistrationCount: Int { pushRegs.count }
    public func setPushEnabled(_ on: Bool) { pushEnabled = on }
    public func scriptPush(_ replies: [WireReply]) { pushScript = replies }
    public var pushRegisterRequests: Int { pushRegisterCalls }
    /// Tests: the registration ids named by unregister requests (a `null` request is not listed).
    public var pushUnregisteredIDs: [ID16] { pushUnregisterIDs }

    func pushRoute(_ r: WireRequest, _ which: String, _ query: String?) -> WireReply {
        guard pushEnabled else { return refuse(404, .notFound) }
        if !pushScript.isEmpty { return pushScript.removeFirst() }
        guard let session = authenticate(r) else { return refuse(401, .unauthenticated) }
        guard session.kind == .device else { return refuse(403, .notEligible) }
        guard query == nil, r.body.count <= 16 << 10, let o = try? StrictJSON.parse(r.body, maxBytes: 16 << 10).object,
              let ws = o["workspace_id"]?.string.flatMap(ID16.init(hex:)) else { return refuse(400, .malformed) }
        if revoked.contains(session.id) { return refuse(403, .revoked) }
        if which == "register" { return pushRegister(o, ws: ws, session) }
        return pushUnregister(o, ws: ws, session)
    }

    private func pushRegister(_ o: [String: JSONValue], ws: ID16, _ s: Session) -> WireReply {
        guard Set(o.keys) == ["workspace_id", "registration_id", "env", "topic", "token"],
              let id = o["registration_id"]?.string.flatMap(ID16.init(hex:)), let env = o["env"]?.string, ["sandbox", "production"].contains(env),
              o["topic"]?.string == Self.pushTopic, let token = o["token"]?.string, let raw = B64U.decode(token), (32...100).contains(raw.count)
        else { return refuse(400, .malformed) }
        if let gate = memberGate(s, ws: ws) { return gate }
        pushRegisterCalls += 1
        let key = PushKey(device: s.id, workspace: ws, env: env, topic: Self.pushTopic)
        // The id is the device's: held by another device, or by this device under another body, is a conflict.
        if pushRegs.contains(where: { $0.key.device != s.id && $0.value.id == id }) { return refuse(409, .registrationConflict) }
        if let sameID = pushRegs.first(where: { $0.key.device == s.id && $0.value.id == id }), sameID.key != key || sameID.value.token != token {
            return refuse(409, .registrationConflict)
        }
        // The token moves from the person's other devices; a new id retires this key's old registration.
        for (k, v) in pushRegs where v.token == token && k.device != s.id { pushRegs[k] = nil }
        pushRegs[key] = PushReg(id: id, token: token)
        return json(200, ["registration_id": .string(id.hex), "registered": .bool(true)])
    }

    private func pushUnregister(_ o: [String: JSONValue], ws: ID16, _ s: Session) -> WireReply {
        guard Set(o.keys) == ["workspace_id", "registration_id"] else { return refuse(400, .malformed) }
        switch o["registration_id"] {
        case .some(.null):
            for k in pushRegs.keys where k.device == s.id && k.workspace == ws { pushRegs[k] = nil }
            return json(200, ["registration_id": .null, "registered": .bool(false)])
        case .some(.string(let h)):
            guard let id = ID16(hex: h) else { return refuse(400, .malformed) }
            pushUnregisterIDs.append(id)
            if pushRegs.contains(where: { $0.key.device != s.id && $0.value.id == id }) { return refuse(403, .notForThisDevice) }
            for (k, v) in pushRegs where k.device == s.id && k.workspace == ws && v.id == id { pushRegs[k] = nil }
            return json(200, ["registration_id": .string(h), "registered": .bool(false)])
        default: return refuse(400, .malformed)
        }
    }
}
