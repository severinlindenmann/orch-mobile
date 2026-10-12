import Foundation
import OrchProtocol

/// Everything a notification shows, built ONLY from verified payload fields and app-authored text. The relay's alert,
/// title, sound, category, thread and userInfo are never inputs (whoever holds the APNs key controls them).
public struct PushPresentation: Equatable, Sendable {
    public enum Style: String, Sendable, Equatable { case generic, event, closed }

    public let style: Style
    public let title: String
    public let body: String
    /// Hex of the verified workspace id; nil for generic.
    public let threadID: String?
    /// `<ws hex>/<id>`: the scope of "replace the delivered question". Nil for generic.
    public let entityKey: String?
    /// `question.closed`: remove delivered notifications whose entity key equals this one.
    public let removesDelivered: String?
    public let sound: Bool
    public let simulated: Bool

    public static let genericTitle = "orch"
    public static let genericBody = "New activity in orch"

    /// Drop, timeout, missing material, removed workspace, unreadable state: fixed app-authored text, no routing.
    /// A documented native exception to protocol section 9's "drop" (decision A12): an OS notification that the
    /// extension cannot suppress still appears, so it says nothing.
    public static let generic = PushPresentation(style: .generic, title: genericTitle, body: genericBody, threadID: nil,
                                                 entityKey: nil, removesDelivered: nil, sound: false, simulated: false)

    /// The "Answered on ..." replacement for a question's notification. The ONE builder for the extension (real push), the Demo
    /// simulator and the app's own replace/reconcile, so they cannot diverge.
    public static func closed(workspaceHex: String, id: String, workspaceName: String, body: String, simulated: Bool = false) -> PushPresentation {
        let key = "\(workspaceHex)/\(id)"
        let name = NotificationText.safe(workspaceName, limit: 80)
        return PushPresentation(style: .closed, title: name.isEmpty ? genericTitle : name, body: body, threadID: workspaceHex,
                                entityKey: key, removesDelivered: key, sound: false, simulated: simulated)
    }

    /// Body for a question closed on a device whose label the host recorded (protocol section 13 wording).
    public static func answeredBody(deviceLabel: String) -> String {
        let label = NotificationText.safe(deviceLabel, limit: PushProcessor.maxLabelCodePoints)
        return label.isEmpty ? "Answered" : "Answered on \(label)"
    }

    /// userInfo keys the app reads back to find a notification's question. Lookup keys only, never an instruction (see NotificationService).
    public static let keyInfo = "orch_key", workspaceInfo = "orch_ws", closedInfo = "orch_closed", simulatedInfo = "orch_simulated"

    public var userInfo: [String: String] {
        var info: [String: String] = [:]
        if let k = entityKey, let t = threadID { info[Self.keyInfo] = k; info[Self.workspaceInfo] = t }
        if style == .closed { info[Self.closedInfo] = "1" }
        if simulated { info[Self.simulatedInfo] = "1" }
        return info
    }

    /// - Parameter workspaceName: from the pinned push material (the signed card), never from the push.
    public static func make(_ p: PushProcessor.Payload, workspaceName: String, simulated: Bool = false) -> PushPresentation {
        let key = "\(p.workspace.hex)/\(p.id)"
        let name = NotificationText.safe(workspaceName, limit: 80)
        let title = name.isEmpty ? genericTitle : name
        let label = NotificationText.safe(p.label, limit: PushProcessor.maxLabelCodePoints)
        switch p.kind {
        case "question.closed":
            // Protocol section 13: the label is "Answered on <device label>"; no fetch in the extension.
            return closed(workspaceHex: p.workspace.hex, id: p.id, workspaceName: workspaceName,
                          body: label.isEmpty ? "Answered" : label, simulated: simulated)
        case "join":
            // Verified but not displayed (gap 13): the extension cannot suppress, so the OS shows generic text.
            return PushPresentation(style: .generic, title: genericTitle, body: genericBody, threadID: nil, entityKey: nil,
                                    removesDelivered: nil, sound: false, simulated: simulated)
        default:
            return PushPresentation(style: .event, title: title, body: label.isEmpty ? genericBody : label, threadID: p.workspace.hex,
                                    entityKey: key, removesDelivered: nil, sound: true, simulated: simulated)
        }
    }
}

/// Text from a signed payload is still host-chosen: strip control and bidi/format characters (a label must not be able
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
    /// The single renderer: the notification service extension, Demo scheduling and in-app replacement all build content here.
    public func notificationContent() -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        if simulated { c.subtitle = PushSimulator.label }
        if let t = threadID { c.threadIdentifier = t }
        if sound { c.sound = .default }
        c.userInfo = userInfo
        return c
    }
}
#endif
