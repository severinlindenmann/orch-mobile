import Foundation
import OrchPush
import UserNotifications
import os

/// Resumes exactly once: with the OS callback's value, or with nil ("unknown") if the notification daemon does not answer
/// within `seconds`. A stalled `usernotificationsd` must not hold up app start or a Demo reset (seen on a wedged simulator runtime).
/// `resumes` (tests) counts continuation resumes; it must end at 1.
func boundedOSCall<T: Sendable>(seconds: Double = 2, resumes: OSAllocatedUnfairLock<Int>? = nil,
                                _ call: @escaping @Sendable (@escaping @Sendable (T) -> Void) -> Void) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let once = OSAllocatedUnfairLock(initialState: false)
        @Sendable func finish(_ value: T?) {
            let first = once.withLock { done -> Bool in if done { return false }; done = true; return true }
            if first { resumes?.withLock { $0 += 1 }; continuation.resume(returning: value) }
        }
        call(finish)
        DispatchQueue.global().asyncAfter(deadline: .now() + max(seconds, 0.01)) { finish(nil) }
    }
}

/// The OS objects stay inside completion handlers; only Sendable identifiers cross the async boundary (Xcode 16.4).
protocol DemoNotificationBackend: LocalNotificationScheduling {
    func purge(workspace: String?) async
}

struct SystemDemoNotifications: DemoNotificationBackend {
    func schedule(_ presentation: PushPresentation, identifier: String) async {
        await UNUserNotificationScheduler().schedule(presentation, identifier: identifier)
    }
    func schedule(_ presentation: PushPresentation, identifier: String, delay: TimeInterval) async {
        await UNUserNotificationScheduler().schedule(presentation, identifier: identifier, delay: delay)
    }
    func removeDelivered(identifiers: [String]) async {
        await UNUserNotificationScheduler().removeDelivered(identifiers: identifiers)
    }
    static func matchesDelivered(identifier: String, thread: String, workspace: String?) -> Bool {
        if let workspace { return thread == workspace || identifier.hasPrefix("demo/\(workspace)/") }
        return identifier.hasPrefix("demo/") || identifier.hasPrefix("sim/")
    }
    /// Whole purge shares ONE deadline (`budget` seconds). If the daemon did not answer in time the purge is owed:
    /// recorded in UserDefaults and retried by `retryOwedPurges()` on the next boot.
    func purge(workspace: String?) async { await purge(workspace: workspace, budget: 2) }

    func purge(workspace: String?, budget: Double) async {
        let deadline = Date().addingTimeInterval(budget)
        func left() -> Double { max(deadline.timeIntervalSinceNow, 0.01) }
        let prefix = workspace.map { "demo/\($0)/" } ?? "demo/"
        var complete = true
        // Stop pending delivery before taking the delivered snapshot.
        let snapshot: [String]? = await boundedOSCall(seconds: left()) { done in
            UNUserNotificationCenter.current().getPendingNotificationRequests { values in
                done(values.filter {
                    $0.identifier.hasPrefix(prefix) ||
                    ($0.identifier.hasPrefix("sim/") && (workspace == nil || $0.content.threadIdentifier == workspace))
                }.map(\.identifier))
            }
        }
        if snapshot == nil { complete = false }
        let pending = snapshot ?? []
        let center = UNUserNotificationCenter.current()
        // Removal has no completion handler. Observe that the requests are gone before enumerating delivered
        // notifications, including any that fired during removal. Bounded by the shared deadline.
        var remaining = pending
        var attempts = 0
        while !remaining.isEmpty, attempts < 10, Date() < deadline {
            if attempts > 0 { try? await Task.sleep(nanoseconds: 50_000_000) }
            attempts += 1
            center.removePendingNotificationRequests(withIdentifiers: remaining)
            let again: [String]? = await boundedOSCall(seconds: left()) { done in
                UNUserNotificationCenter.current().getPendingNotificationRequests { values in
                    done(values.map(\.identifier).filter { pending.contains($0) })
                }
            }
            if let again { remaining = again } else { complete = false; break }
        }
        if !remaining.isEmpty { complete = false }
        let delivered: [String]? = await boundedOSCall(seconds: left()) { done in
            UNUserNotificationCenter.current().getDeliveredNotifications { values in
                done(values.filter {
                    Self.matchesDelivered(identifier: $0.request.identifier,
                                          thread: $0.request.content.threadIdentifier, workspace: workspace)
                }.map { $0.request.identifier })
            }
        }
        if delivered == nil { complete = false }
        let identifiers = Array(Set((delivered ?? []) + pending))
        if !identifiers.isEmpty { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
        Self.setOwed(workspace, !complete)
    }

    // MARK: owed purges (daemon did not answer in time)

    static let owedKey = "orch.demo.notificationPurgeOwed"
    static func owed(_ defaults: UserDefaults = .standard) -> Set<String> { Set(defaults.stringArray(forKey: owedKey) ?? []) }
    /// Serialises the read-modify-write: the boot purge and retryOwedPurges can run concurrently.
    private static let owedLock = NSLock()
    static func setOwed(_ workspace: String?, _ owed: Bool, defaults: UserDefaults = .standard) {
        owedLock.lock(); defer { owedLock.unlock() }
        var all = Self.owed(defaults)
        let key = workspace ?? "*"
        if owed { all.insert(key) } else {
            all.remove(key)
            if workspace == nil { all = [] }   // a complete whole-Demo purge covers every workspace
        }
        defaults.set(Array(all).sorted(), forKey: owedKey)
    }

    /// Retries purges that timed out earlier. Call detached after boot; never awaited by app start.
    func retryOwedPurges() async {
        for key in Self.owed().sorted() { await purge(workspace: key == "*" ? nil : key) }
    }
}

/// Closing a scope prevents new schedules, drains every schedule already in flight, then purges both OS queues.
actor DemoNotifications {
    private let backend: any DemoNotificationBackend
    private var closed: Set<String> = []
    private var retired = false
    /// Boot-time stale purge: scheduling by the NEW runtime waits for it (the purge removes demo/ and sim/ by prefix).
    private var gate: Task<Void, Never>?
    private var tasks: [UUID: (String, Task<Void, Never>)] = [:]
    private let onDrain: @Sendable () async -> Void
    init(backend: any DemoNotificationBackend = SystemDemoNotifications(),
         onDrain: @escaping @Sendable () async -> Void = {}) {
        self.backend = backend; self.onDrain = onDrain
    }

    /// Schedules issued before `task` finishes wait for it. The task is bounded (one shared purge deadline).
    func hold(until task: Task<Void, Never>) { gate = task }

    func schedule(_ presentation: PushPresentation, identifier: String, workspace: String, delay: TimeInterval = 1) async {
        if let gate { await gate.value }
        guard !retired, !closed.contains(workspace) else { return }
        let key = UUID()
        let task = Task { await backend.schedule(presentation, identifier: "demo/\(workspace)/\(identifier)", delay: delay) }
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
    func schedule(_ presentation: PushPresentation, identifier: String, delay: TimeInterval) async {
        await owner.schedule(presentation, identifier: identifier, workspace: workspace, delay: delay)
    }
    func removeDelivered(identifiers: [String]) async { await owner.remove(identifiers, workspace: workspace) }
}
