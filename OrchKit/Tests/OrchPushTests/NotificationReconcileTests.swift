import Foundation
import Testing
@testable import OrchPush

private actor RecordingCenter: NotificationCentering {
    enum Call: Equatable { case post(String, String, String), remove(String) }
    private let list: [DeliveredNotification]
    private(set) var calls: [Call] = []
    init(_ list: [DeliveredNotification]) { self.list = list }
    func delivered() -> [DeliveredNotification] { list }
    func post(_ p: PushPresentation, identifier: String) { calls.append(.post(identifier, p.title, p.body)) }
    func remove(identifiers: [String]) { identifiers.forEach { calls.append(.remove($0)) } }
}

@Suite struct NotificationReconcileTests {
    static let key = "aabb/q1"
    let closed: [String: QuestionClosure] = [key: QuestionClosure(workspaceName: "Fixture", deviceLabel: "Demo Mac")]

    @Test func closedQuestionReplacesWithSameIdentifier() {
        let n = DeliveredNotification(identifier: "demo/aabb/sim/aabb/q1", entityKey: Self.key, isClosure: false, simulated: true)
        let out = NotificationReconciler.actions(delivered: [n], closed: closed)
        #expect(out.count == 1)
        guard case .replace(let id, let p) = out[0] else { Issue.record("expected replace"); return }
        #expect(id == "demo/aabb/sim/aabb/q1")
        #expect(p.body == "Answered on Demo Mac")
        #expect(p.title == "Fixture")
        #expect(p.threadID == "aabb")
        #expect(p.style == .closed)
        #expect(p.simulated)
        #expect(p.userInfo[PushPresentation.closedInfo] == "1")
    }

    @Test func openOrUnknownAndAlreadyClosedAreLeftAlone() {
        let open = DeliveredNotification(identifier: "a", entityKey: "aabb/other", isClosure: false)
        let generic = DeliveredNotification(identifier: "b", entityKey: nil, isClosure: false)
        let done = DeliveredNotification(identifier: "c", entityKey: Self.key, isClosure: true)
        #expect(NotificationReconciler.actions(delivered: [open, generic, done], closed: closed).isEmpty)
    }

    @Test func duplicatesCollapseToOneNotification() {
        let a = DeliveredNotification(identifier: "a", entityKey: Self.key, isClosure: false)
        let b = DeliveredNotification(identifier: "b", entityKey: Self.key, isClosure: false)
        let out = NotificationReconciler.actions(delivered: [b, a], closed: closed)
        #expect(out.count == 2)
        guard case .replace(let id, _) = out[0] else { Issue.record("expected replace"); return }
        #expect(id == "a")
        #expect(out[1] == .remove(identifier: "b"))
    }

    @Test func closureRendersTheSameAsTheExtensionsClosedPresentation() {
        // The extension builds `.closed` from a verified payload; the app builds it from the question state. One builder.
        let viaApp = PushPresentation.closed(workspaceHex: "aabb", id: "q1", workspaceName: "Fixture",
                                             body: PushPresentation.answeredBody(deviceLabel: "laptop"))
        #expect(viaApp.body == "Answered on laptop")
        #expect(viaApp.entityKey == "aabb/q1")
        #expect(viaApp.removesDelivered == "aabb/q1")
        #expect(!viaApp.sound)
    }

    @Test func reconcileAppliesActionsThroughTheCenter() async {
        let center = RecordingCenter([DeliveredNotification(identifier: "x", entityKey: Self.key, isClosure: false),
                                      DeliveredNotification(identifier: "y", entityKey: Self.key, isClosure: false)])
        await NotificationReconciler.reconcile(center: center, closed: closed)
        let calls = await center.calls
        #expect(calls == [.post("x", "Fixture", "Answered on Demo Mac"), .remove("y")])
    }

    @Test func labelIsSanitisedAndEmptyFallsBack() {
        #expect(PushPresentation.answeredBody(deviceLabel: "") == "Answered")
        #expect(PushPresentation.answeredBody(deviceLabel: "Mac\u{202E}x") == "Answered on Macx")
    }
}
