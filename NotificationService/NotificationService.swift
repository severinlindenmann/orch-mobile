import Foundation
import UserNotifications
import OrchPush

/// Both lifecycle callbacks consume the same lock-protected completion.
/// The handler is invoked outside the lock to permit reentrancy.
private final class CompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: ((UNNotificationContent) -> Void)?
    private var expired = false

    func install(_ handler: @escaping (UNNotificationContent) -> Void) {
        lock.lock()
        pending = handler
        let shouldFinish = expired
        lock.unlock()
        if shouldFinish { finish() }
    }

    func finish(expiring: Bool = false) {
        lock.lock()
        if expiring { expired = true }
        let handler = pending
        pending = nil
        lock.unlock()

        // Construct fresh app-authored content; never echo unverified payload text.
        let content = UNMutableNotificationContent()
        content.body = "New activity in orch"
        handler?(content)
    }
}

final class NotificationService: UNNotificationServiceExtension {
    private let completion = CompletionGate()

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        completion.install(contentHandler)
        completion.finish()
    }

    override func serviceExtensionTimeWillExpire() {
        completion.finish(expiring: true)
    }
}
