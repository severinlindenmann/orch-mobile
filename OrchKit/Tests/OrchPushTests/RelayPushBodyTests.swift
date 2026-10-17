import Foundation
import OrchProtocol
import OrchPushFixtures
import Testing
@testable import OrchPush

/// What the notification extension receives from the relay (protocol-v2 section 19.10): the real APNs JSON, parsed the way iOS hands it
/// over as `userInfo`.
struct RelayPushBodyTests {
    let a = PushFixtures.workspaceA

    func userInfo(_ body: Data) -> [AnyHashable: Any] {
        (try! JSONSerialization.jsonObject(with: body)) as! [AnyHashable: Any]
    }

    func sealed(kind: String, id: String, label: String, tsMs: Int64 = nowMs) -> String {
        PushFixtures.seal(a, PushFixtures.payload(kind: kind, id: id, label: label, tsMs: tsMs))
    }

    @Test func aRelayShapedBodyIsShownFromTheVerifiedPayloadNotTheRelayText() {
        let outer = sealed(kind: "question", id: "q-1", label: "Ship L-0042?")
        let body = PushFixtures.relayBody(outer: outer)
        #expect(body.count <= RelayPushBody.maxBodyBytes)
        let info = userInfo(body)
        #expect(Set(info.keys.compactMap { $0 as? String }) == ["aps", "o"])
        let o = RelayPushBody.outer(userInfo: info)
        #expect(o == outer)
        let r = handler(dir: tmp(), [a.id: material(a)]).handle(o: o)
        #expect(r.presentation.style == .event && r.presentation.body == "Ship L-0042?" && r.presentation.title == a.name)
        #expect(r.presentation.sound)                       // the relay sends no sound: the extension adds it for verified events
    }

    @Test func theRelayAlertTextIsTheExtensionsOwnGenericText() {
        #expect(RelayPushBody.alertTitle == PushPresentation.generic.title && RelayPushBody.alertBody == PushPresentation.generic.body)
        let aps = userInfo(PushFixtures.relayBody(outer: sealed(kind: "question", id: "q", label: "x")))["aps"] as! [String: Any]
        let alert = aps["alert"] as! [String: Any]
        #expect(alert["title"] as? String == RelayPushBody.alertTitle && alert["body"] as? String == RelayPushBody.alertBody)
        #expect(aps["mutable-content"] as? Int == 1)
        #expect(Set(aps.keys) == ["alert", "mutable-content"])       // no badge, sound, thread-id or category
    }

    @Test func anOuterThatIsNotAStringIsAGenericDrop() {
        let outer = sealed(kind: "question", id: "q-2", label: "x")
        let asObject = ["aps": ["alert": ["title": "orch", "body": "New activity in orch"], "mutable-content": 1], "o": try! JSONSerialization.jsonObject(with: Data(outer.utf8))] as [String: Any]
        #expect(RelayPushBody.outer(userInfo: asObject) == nil)
        #expect(RelayPushBody.outer(userInfo: ["o": 5]) == nil && RelayPushBody.outer(userInfo: [:]) == nil)
        let r = handler(dir: tmp(), [a.id: material(a)]).handle(o: RelayPushBody.outer(userInfo: asObject))
        #expect(r.presentation == .generic)
    }

    @Test func aMaximalOuterFitsTheRelaysBodyBound() {
        // 3 072 bytes of outer JSON (the cap), with the quote-heavy shape of the real object.
        var c = String(repeating: "A", count: 3072)
        let head = "{\"v\":2,\"ws\":\"" + a.id.hex + "\",\"epoch\":1,\"c\":\"", tail = "\"}"
        c = String(c.prefix(3072 - head.utf8.count - tail.utf8.count))
        let outer = head + c + tail
        #expect(outer.utf8.count == 3072)
        let body = PushFixtures.relayBody(outer: outer)
        #expect(body.count <= RelayPushBody.maxBodyBytes)
        // the extension takes it up to the cap and drops it as malformed (it is not sealed), generic, not as an oversize
        let r = handler(dir: tmp(), [a.id: material(a)]).handle(o: RelayPushBody.outer(userInfo: userInfo(body)))
        #expect(r.presentation == .generic)
    }

    @Test func aClosedPushReplacesTheQuestionByEntityKeyWithoutACollapseId() {
        let dir = tmp(), h = handler(dir: dir, [a.id: material(a)])
        let q = h.handle(o: RelayPushBody.outer(userInfo: userInfo(PushFixtures.relayBody(outer: sealed(kind: "question", id: "q-3", label: "Go?", tsMs: nowMs - 2000)))))
        let c = h.handle(o: RelayPushBody.outer(userInfo: userInfo(PushFixtures.relayBody(outer: sealed(kind: "question.closed", id: "q-3", label: "Answered on Mac", tsMs: nowMs - 1000)))))
        #expect(q.presentation.style == .event && c.presentation.style == .closed)
        #expect(q.presentation.entityKey == "\(a.id.hex)/q-3")
        #expect(c.presentation.removesDelivered == q.presentation.entityKey)
        // every push carries its own request identifier at the OS; the userInfo key is what ties the two
        #expect(q.presentation.userInfo[PushPresentation.keyInfo] == c.presentation.userInfo[PushPresentation.keyInfo])
    }
}
