import Foundation
import UserNotifications
import OrchPush

final class NotificationService: UNNotificationServiceExtension {
    // TODO(M7): replace generic body with the A12 PushProcessor
    // Construct fresh app-authored content; never echo unverified payload text.
    private let completion = CompletionGate<UNNotificationContent> {
        let content = UNMutableNotificationContent()
        content.body = "New activity in orch"
        return content
    }

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
