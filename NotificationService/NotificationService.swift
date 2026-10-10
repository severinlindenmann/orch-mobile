import Foundation
import UserNotifications
import OrchPush

/// Decision A12 (protocol section 9, suite 2). Everything shown is app-authored or comes from the verified payload:
/// the relay's title, subtitle, body, sound, category, thread and userInfo are never read. Every drop, timeout or
/// missing-material path delivers fixed generic text (a documented native exception to "drop": the OS shows
/// something anyway and the extension cannot suppress it). The extension writes its own invocation marker (counter,
/// outcome, timestamp; no content) so tests can tell "the extension ran" from "a notification appeared".
/// No signing, no network, no FakeHost: it links OrchPush (+ OrchProtocol, OrchCoordination for the removal lock).
///
/// TAP ROUTING MUST NEVER TRUST `userInfo`. `orch_key` / `orch_ws` below are set by this extension, but a malicious
/// relay can skip the extension (omit `mutable-content`) and deliver any userInfo it likes. The app must treat them
/// only as a lookup key into locally verified data (re-verify, fetch authoritative state, then act: U10), never as
/// an instruction or an identity.
///
/// The processing and the expiry race are in `PushDelivery` (tested in OrchPushTests): processing runs off this
/// callback thread, `serviceExtensionTimeWillExpire` completes at once with generic content and does no blocking I/O.
final class NotificationService: UNNotificationServiceExtension {
    private var delivery: PushDelivery?

    /// Fresh content built from a presentation. `userInfo` holds only identifiers of the verified payload (lookup keys).
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
        guard let dir = Self.pushDir(), let source = KeychainPushMaterialSource.fromBundle() else {
            contentHandler(Self.content(for: .generic))
            return
        }
        let d = PushDelivery(handler: PushHandler(material: source, pushDir: dir)) { key, done in
            // "Answered on ...": remove the delivered question of the same (workspace, id), then deliver the closure.
            let center = UNUserNotificationCenter.current()
            center.getDeliveredNotifications { delivered in
                let old = delivered.filter { ($0.request.content.userInfo["orch_key"] as? String).map { Data($0.utf8) == Data(key.utf8) } ?? false }
                    .map(\.request.identifier)
                center.removeDeliveredNotifications(withIdentifiers: old)
                done()
            }
        }
        delivery = d
        d.start(o: request.content.userInfo["o"] as? String) { contentHandler(Self.content(for: $0)) }
    }

    override func serviceExtensionTimeWillExpire() {
        delivery?.expire()
    }
}
