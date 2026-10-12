import Foundation

/// A notification the OS holds for this app (delivered, or scheduled but not yet shown), reduced to what reconcile needs.
public struct DeliveredNotification: Equatable, Sendable {
    public let identifier: String
    /// `<ws hex>/<question id>` from the content's userInfo; nil when the notification carries none (generic).
    public let entityKey: String?
    /// Already the "Answered on ..." replacement.
    public let isClosure: Bool
    /// Local (Demo) notification: the replacement keeps the "simulated" label.
    public let simulated: Bool
    public init(identifier: String, entityKey: String?, isClosure: Bool, simulated: Bool = false) {
        self.identifier = identifier; self.entityKey = entityKey; self.isClosure = isClosure; self.simulated = simulated
    }
}

/// What the app knows about a question that is closed.
public struct QuestionClosure: Equatable, Sendable {
    public let workspaceName: String
    /// The device the host recorded as having answered.
    public let deviceLabel: String
    public init(workspaceName: String, deviceLabel: String) { self.workspaceName = workspaceName; self.deviceLabel = deviceLabel }
}

/// The notification centre as the app sees it. The app supplies `UNNotificationCentering`; tests supply a recorder.
public protocol NotificationCentering: Sendable {
    func delivered() async -> [DeliveredNotification]
    /// Immediate post. With the identifier of a delivered or pending notification this REPLACES it in place.
    func post(_ presentation: PushPresentation, identifier: String) async
    func remove(identifiers: [String]) async
}

/// Reconcile-on-open and replace-on-closed: pure decisions from the OS's notification list and the known question states.
/// A real push gets its replacement from the extension when it can run; this covers every other path (the extension never
/// ran, the push arrived before the question closed elsewhere, Demo's local notifications which never reach an extension).
public enum NotificationReconciler {
    public enum Action: Equatable, Sendable {
        case replace(identifier: String, PushPresentation)
        case remove(identifier: String)
    }

    /// - Parameter closed: entity key -> closure, for questions known to be closed.
    public static func actions(delivered: [DeliveredNotification], closed: [String: QuestionClosure]) -> [Action] {
        var out: [Action] = []
        var replaced: Set<String> = []
        for n in delivered.sorted(by: { $0.identifier < $1.identifier }) {
            guard let key = n.entityKey, let info = closed[key] else { continue }
            if n.isClosure {
                // One closure per question: a second copy (e.g. two devices' pushes) is noise.
                if !replaced.insert(key).inserted { out.append(.remove(identifier: n.identifier)) }
                continue
            }
            if replaced.insert(key).inserted {
                let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                out.append(.replace(identifier: n.identifier, .closed(workspaceHex: parts[0], id: parts[1], workspaceName: info.workspaceName,
                                                                      body: PushPresentation.answeredBody(deviceLabel: info.deviceLabel), simulated: n.simulated)))
            } else {
                out.append(.remove(identifier: n.identifier))
            }
        }
        return out
    }

    /// Applies the actions to the centre and returns them.
    @discardableResult
    public static func reconcile(center: any NotificationCentering, closed: [String: QuestionClosure]) async -> [Action] {
        guard !closed.isEmpty else { return [] }
        let list = await center.delivered()
        let todo = actions(delivered: list, closed: closed)
        for a in todo {
            switch a {
            case .replace(let id, let p): await center.post(p, identifier: id)
            case .remove(let id): await center.remove(identifiers: [id])
            }
        }
        return todo
    }
}

#if canImport(UserNotifications)
import UserNotifications

public struct UNNotificationCentering: NotificationCentering {
    public init() {}
    private static func reduce(_ r: UNNotificationRequest) -> DeliveredNotification {
        let info = r.content.userInfo
        return DeliveredNotification(identifier: r.identifier, entityKey: info[PushPresentation.keyInfo] as? String,
                                     isClosure: (info[PushPresentation.closedInfo] as? String) == "1",
                                     simulated: (info[PushPresentation.simulatedInfo] as? String) == "1")
    }
    public func delivered() async -> [DeliveredNotification] {
        let shown: [DeliveredNotification] = await withCheckedContinuation { c in
            UNUserNotificationCenter.current().getDeliveredNotifications { c.resume(returning: $0.map { Self.reduce($0.request) }) }
        }
        let pending: [DeliveredNotification] = await withCheckedContinuation { c in
            UNUserNotificationCenter.current().getPendingNotificationRequests { c.resume(returning: $0.map(Self.reduce)) }
        }
        return shown + pending
    }
    public func post(_ p: PushPresentation, identifier: String) async {
        let req = UNNotificationRequest(identifier: identifier, content: p.notificationContent(), trigger: nil)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            UNUserNotificationCenter.current().add(req) { _ in c.resume() }
        }
    }
    public func remove(identifiers: [String]) async {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}
#endif
