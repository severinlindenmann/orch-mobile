import Foundation
import UserNotifications
import OrchPush

/// Decision A12 (protocol section 9, suite 2). Everything shown is app-authored or comes from the verified payload:
/// the relay's title, subtitle, body, sound, category, thread and userInfo are never read. Every drop, timeout or
/// missing-material path delivers fixed generic text (a documented native exception to "drop": the OS shows
/// something anyway and the extension cannot suppress it). The extension writes its own invocation marker (counter,
/// outcome, timestamp; no content) so tests can tell "the extension ran" from "a notification appeared".
/// No signing, no network, no FakeHost: it links OrchPush (+ OrchProtocol, OrchStore for the removal lock).
final class NotificationService: UNNotificationServiceExtension {
    /// What the completion delivers; read at delivery time, so a timeout that wins the race delivers generic text.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var presentation = PushPresentation.generic
        private var delivered = false
        func set(_ p: PushPresentation) { lock.lock(); presentation = p; lock.unlock() }
        func take() -> PushPresentation { lock.lock(); delivered = true; let p = presentation; lock.unlock(); return p }
        var wasDelivered: Bool { lock.lock(); defer { lock.unlock() }; return delivered }
    }

    private let box = Box()
    private lazy var completion = CompletionGate<UNNotificationContent> { [box] in Self.content(for: box.take()) }
    private var handler: PushHandler?

    /// Fresh content built from a presentation. `userInfo` holds only verified identifiers.
    static func content(for p: PushPresentation) -> UNNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = p.title
        c.body = p.body
        if let t = p.threadID { c.threadIdentifier = t }
        if p.sound { c.sound = .default }
        if let k = p.entityKey, let t = p.threadID { c.userInfo = ["orch_key": k, "orch_ws": t] }
        return c
    }

    private static func pushDir() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.io.severin.orch")?
            .appendingPathComponent("push", isDirectory: true)
    }

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        completion.install(contentHandler)
        guard let dir = Self.pushDir(), let source = KeychainPushMaterialSource.fromBundle() else {
            completion.finish()
            return
        }
        let h = PushHandler(material: source, pushDir: dir)
        handler = h
        let result = h.handle(o: request.content.userInfo["o"] as? String)
        box.set(result.presentation)
        guard let key = result.presentation.removesDelivered else { completion.finish(); return }
        // "Answered on ...": remove the delivered question of the same (workspace, id), then deliver the closure.
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { [completion] delivered in
            let old = delivered.filter { ($0.request.content.userInfo["orch_key"] as? String).map { Data($0.utf8) == Data(key.utf8) } ?? false }
                .map(\.request.identifier)
            center.removeDeliveredNotifications(withIdentifiers: old)
            completion.finish()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if !box.wasDelivered { handler?.recordExpired() }
        box.set(.generic)
        completion.finish(expiring: true)
    }
}
