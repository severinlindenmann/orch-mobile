import Foundation
import OrchPush
import UserNotifications

/// The OS objects stay inside completion handlers; only Sendable identifiers cross the async boundary (Xcode 16.4).
protocol DemoNotificationBackend: LocalNotificationScheduling {
    func purge(workspace: String?) async
}

struct SystemDemoNotifications: DemoNotificationBackend {
    func schedule(_ presentation: PushPresentation, identifier: String) async {
        await UNUserNotificationScheduler().schedule(presentation, identifier: identifier)
    }
    func removeDelivered(identifiers: [String]) async {
        await UNUserNotificationScheduler().removeDelivered(identifiers: identifiers)
    }
    func purge(workspace: String?) async {
        let prefix = workspace.map { "demo/\($0)/" } ?? "demo/"
        // Read pending first: a request that fires during enumeration is then covered
        // by either snapshot. Remove the union from both queues to cover that transition.
        let pending: [String] = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getPendingNotificationRequests { values in
                continuation.resume(returning: values.filter {
                    $0.identifier.hasPrefix(prefix) ||
                    ($0.identifier.hasPrefix("sim/") && (workspace == nil || $0.content.threadIdentifier == workspace))
                }.map(\.identifier))
            }
        }
        let delivered: [String] = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getDeliveredNotifications { values in
                continuation.resume(returning: values.filter {
                    $0.request.identifier.hasPrefix(prefix) ||
                    ($0.request.identifier.hasPrefix("sim/") && (workspace == nil || $0.request.content.threadIdentifier == workspace))
                }.map { $0.request.identifier })
            }
        }
        let center = UNUserNotificationCenter.current()
        let identifiers = Array(Set(delivered + pending))
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

/// Closing a scope prevents new schedules, drains every schedule already in flight, then purges both OS queues.
actor DemoNotifications {
    private let backend: any DemoNotificationBackend
    private var closed: Set<String> = []
    private var retired = false
    private var tasks: [UUID: (String, Task<Void, Never>)] = [:]
    init(backend: any DemoNotificationBackend = SystemDemoNotifications()) { self.backend = backend }

    func schedule(_ presentation: PushPresentation, identifier: String, workspace: String) async {
        guard !retired, !closed.contains(workspace) else { return }
        let key = UUID()
        let task = Task { await backend.schedule(presentation, identifier: "demo/\(workspace)/\(identifier)") }
        tasks[key] = (workspace, task)
        await task.value
        tasks[key] = nil
    }
    func remove(_ identifiers: [String], workspace: String) async {
        await backend.removeDelivered(identifiers: identifiers.map { "demo/\(workspace)/\($0)" })
    }
    func purge(workspace: String? = nil) async {
        if let workspace { closed.insert(workspace) } else { retired = true }
        let pending = tasks.values.filter { workspace == nil || $0.0 == workspace }.map { $0.1 }
        for task in pending { await task.value }
        await backend.purge(workspace: workspace)
    }
}

struct ScopedDemoNotifications: LocalNotificationScheduling {
    let owner: DemoNotifications
    let workspace: String
    func schedule(_ presentation: PushPresentation, identifier: String) async {
        await owner.schedule(presentation, identifier: identifier, workspace: workspace)
    }
    func removeDelivered(identifiers: [String]) async { await owner.remove(identifiers, workspace: workspace) }
}
