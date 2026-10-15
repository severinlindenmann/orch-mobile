import XCTest
import OrchProtocol
import OrchPush
@testable import Orch

/// Records what the Demo schedules and what the app posts/removes afterwards. No UserNotifications, no extension.
private actor RecordingCenter: DemoNotificationBackend, NotificationCentering {
    struct Post: Equatable { let identifier: String; let title: String; let body: String; let thread: String? }
    private(set) var scheduled: [(identifier: String, presentation: PushPresentation)] = []
    private(set) var posts: [Post] = []
    private(set) var removed: [String] = []

    func schedule(_ presentation: PushPresentation, identifier: String) { scheduled.append((identifier, presentation)) }
    func removeDelivered(identifiers: [String]) {}
    func purge(workspace: String?) {}

    func delivered() -> [DeliveredNotification] {
        scheduled.map { item in
            let info = item.presentation.userInfo
            return DeliveredNotification(identifier: item.identifier, entityKey: info[PushPresentation.keyInfo],
                                         isClosure: info[PushPresentation.closedInfo] == "1",
                                         simulated: info[PushPresentation.simulatedInfo] == "1")
        }
    }
    func post(_ presentation: PushPresentation, identifier: String) {
        posts.append(Post(identifier: identifier, title: presentation.title, body: presentation.body, thread: presentation.threadID))
        // Same identifier replaces the earlier request, as the OS does.
        scheduled.removeAll { $0.identifier == identifier }
        scheduled.append((identifier, presentation))
    }
    func remove(identifiers: [String]) {
        removed += identifiers
        scheduled.removeAll { identifiers.contains($0.identifier) }
    }
}

@MainActor
final class DemoNotificationReplaceTests: XCTestCase {
    private let options = LaunchOptions.parse(arguments: ["--ui-testing"], debug: true)

    private func pairOneWorkspace(_ services: LiveServices, _ runtime: DemoRuntime) async {
        runtime.speed = 10
        let model = LivePairingModel(services: services, start: nil)
        model.useDemoInvitation()
        let deadline = Date().addingTimeInterval(90)
        var done = false
        while !done, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            switch model.state {
            case .comparingHost where !model.demoHostCode.isEmpty: model.hostApprove()
            case .waitingPrimary: model.primaryOpenRequest()
            case .comparingPrimary where model.demoPrimaryHasChallenge: model.primaryApprove()
            case .ready, .refused, .alarm, .expired, .denied: done = true
            default: break
            }
        }
        model.cancel()
        runtime.speed = 1
    }

    func testClosingTheQuestionReplacesTheDemoNotificationUnderTheSameIdentifier() async throws {
        let center = RecordingCenter()
        let runtime = try await DemoRuntime.boot(temporaryStorage: true, notifications: DemoNotifications(backend: center))
        let services = LiveServices(options: options, runtime: runtime)
        services.notificationCenter = center
        services.notificationPermissionOverride = { .allowed }
        await pairOneWorkspace(services, runtime)
        let ws = try XCTUnwrap(services.live.first)
        await ws.refresh()
        let question = try XCTUnwrap(ws.waiting.first)

        // 1. The Demo trigger schedules a local notification FOR THIS QUESTION (not a random id).
        await services.demoSendNotification()
        let scheduled = await center.scheduled
        XCTAssertEqual(scheduled.count, 1)
        let first = try XCTUnwrap(scheduled.first)
        XCTAssertEqual(first.presentation.entityKey, "\(ws.workspaceID.hex)/\(question.id)")
        XCTAssertEqual(first.presentation.style, .event)

        // 2. The question closes at the host while the app runs (no notification extension exists in this path).
        let host = try XCTUnwrap(runtime.entry(for: ws.workspaceID)?.host)
        let qid = try XCTUnwrap(ID16(hex: question.id))
        let option = try XCTUnwrap(question.options.first?.id)
        try await host.demoAnswerOnHost(question: qid, optionID: option, byLabel: "Demo Mac")
        await ws.refresh()
        for _ in 0..<200 { if await !center.posts.isEmpty { break }; try await Task.sleep(for: .milliseconds(25)) }

        // 3. The app replaced it: same identifier, "Answered on" body.
        let posts = await center.posts
        XCTAssertEqual(posts.count, 1)
        let post = try XCTUnwrap(posts.first)
        XCTAssertEqual(post.identifier, first.identifier)
        XCTAssertEqual(post.body, "Answered on Demo Mac")
        XCTAssertEqual(post.thread, ws.workspaceID.hex)

        services.exitDemo()
        await services.waitForReset()
    }

    func testNoOpenQuestionMakesTheHostAskOneAndTheNotificationTargetsIt() async throws {
        let center = RecordingCenter()
        let runtime = try await DemoRuntime.boot(temporaryStorage: true, notifications: DemoNotifications(backend: center))
        let services = LiveServices(options: options, runtime: runtime)
        services.notificationCenter = center
        services.notificationPermissionOverride = { .allowed }
        await pairOneWorkspace(services, runtime)
        let ws = try XCTUnwrap(services.live.first)
        await ws.refresh()
        let host = try XCTUnwrap(runtime.entry(for: ws.workspaceID)?.host)
        for q in ws.waiting {
            try await host.demoAnswerOnHost(question: try XCTUnwrap(ID16(hex: q.id)), optionID: try XCTUnwrap(q.options.first?.id))
        }
        await ws.refresh()
        let seen = Set(ws.questions.map(\.id))
        XCTAssertTrue(ws.waiting.isEmpty)

        await services.demoSendNotification()
        for _ in 0..<200 { if !ws.waiting.isEmpty { break }; try await Task.sleep(for: .milliseconds(25)) }
        let fresh = try XCTUnwrap(ws.waiting.first)
        XCTAssertFalse(seen.contains(fresh.id))
        let scheduled = await center.scheduled
        XCTAssertEqual(scheduled.count, 1)
        let first = try XCTUnwrap(scheduled.first)
        XCTAssertEqual(first.presentation.entityKey, "\(ws.workspaceID.hex)/\(fresh.id)")

        try await host.demoAnswerOnHost(question: try XCTUnwrap(ID16(hex: fresh.id)), optionID: try XCTUnwrap(fresh.options.first?.id), byLabel: "Demo Mac")
        await ws.refresh()
        for _ in 0..<200 { if await !center.posts.isEmpty { break }; try await Task.sleep(for: .milliseconds(25)) }
        let posts = await center.posts
        XCTAssertEqual(posts.first?.identifier, first.identifier)
        XCTAssertEqual(posts.first?.body, "Answered on Demo Mac")

        services.exitDemo()
        await services.waitForReset()
    }
}
