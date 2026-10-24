import Foundation
import OrchProtocol

/// Everything a notification shows, built ONLY from the person's own hub label and app-authored text. The relay's alert, title, sound,
/// category, thread and userInfo are never inputs (whoever holds the APNs key controls them).
public struct PushPresentation: Equatable, Sendable {
    public enum Style: String, Sendable, Equatable { case generic, event }

    public let style: Style
    public let title: String
    public let body: String
    public let sound: Bool

    public static let genericTitle = "orch"
    public static let genericBody = "New activity in orch"

    /// Drop, timeout, missing material, unreadable state: fixed app-authored text, no routing. A documented native exception to "drop"
    /// (decision A12): an OS notification that the extension cannot suppress still appears, so it says nothing.
    public static let generic = PushPresentation(style: .generic, title: genericTitle, body: genericBody, sound: false)
}

/// Text the person chose (the hub label) is still free text: strip control and bidi/format characters (a label must not be able
/// to reorder or hide what the user reads), collapse whitespace.
public enum NotificationText {
    public static func safe(_ s: String, limit: Int) -> String {
        var out = String.UnicodeScalarView()
        var lastSpace = true
        for u in s.unicodeScalars {
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate:
                if u == "\n" || u == "\t" { if !lastSpace { out.append(" "); lastSpace = true } }
                continue
            case .spaceSeparator:
                if !lastSpace { out.append(" "); lastSpace = true }
            default:
                out.append(u); lastSpace = false
            }
            if out.count >= limit { break }
        }
        var r = String(out)
        while r.last == " " { r.removeLast() }
        return r
    }
}

#if canImport(UserNotifications)
import UserNotifications

extension PushPresentation {
    /// The single renderer of the notification service extension.
    public func notificationContent() -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        if sound { c.sound = .default }
        return c
    }
}
#endif
