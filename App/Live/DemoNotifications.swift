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
    static func matchesDelivered(identifier: String, thread: String, workspace: String?) -> Bool {
        if let workspace { return thread == workspace || identifier.hasPrefix("demo/\(workspace)/") }
        return identifier.hasPrefix("demo/") || identifier.hasPrefix("sim/")
    }
    func purge(workspace: String?) async {
        let prefix = workspace.map { "demo/\($0)/" } ?? "demo/"
        // Stop pending delivery before taking the delivered snapshot.
        let pending: [String] = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getPendingNotificationRequests { values in
                continuation.resume(returning: values.filter {
                    $0.identifier.hasPrefix(prefix) ||
                    ($0.identifier.hasPrefix("sim/") && (workspace == nil || $0.content.threadIdentifier == workspace))
                }.map(\.identifier))
            }
        }
        let center = UNUserNotificationCenter.current()
        // Removal has no completion handler. Observe that the requests are gone before
        // enumerating delivered notifications, including any that fired during removal.
        // Bounded: if the OS never reports them gone, Leave/reset must still finish (delivered purge below runs anyway).
        var remaining = pending
        var attempts = 0
        while !remaining.isEmpty, attempts < 10 {
            if attempts > 0 { try? await Task.sleep(nanoseconds: 50_000_000) }
            attempts += 1
            center.removePendingNotificationRequests(withIdentifiers: remaining)
            remaining = await withCheckedContinuation { continuation in
                center.getPendingNotificationRequests { values in
                    continuation.resume(returning: values.map(\.identifier).filter { pending.contains($0) })
                }
            }
        }
        let delivered: [String] = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getDeliveredNotifications { values in
                continuation.resume(returning: values.filter {
                    Self.matchesDelivered(identifier: $0.request.identifier,
                                          thread: $0.request.content.threadIdentifier, workspace: workspace)
                }.map { $0.request.identifier })
            }
        }
        let identifiers = Array(Set(delivered + pending))
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

/// Closing a scope prevents new schedules, drains every schedule already in flight, then purges both OS queues.
actor DemoNotifications {
    private let backend: any DemoNotificationBackend
    private var closed: Set<String> = []
    private var retired = false
    private var tasks: [UUID: (String, Task<Void, Never>)] = [:]
    private let onDrain: @Sendable () async -> Void
    init(backend: any DemoNotificationBackend = SystemDemoNotifications(),
         onDrain: @escaping @Sendable () async -> Void = {}) {
        self.backend = backend; self.onDrain = onDrain
    }

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
        for task in pending {
            await onDrain()
            await task.value
        }
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
