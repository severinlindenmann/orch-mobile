import Foundation
import OrchProtocol
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Where a simulated notification goes. The app supplies `UNUserNotificationScheduler`; tests supply a recorder.
public protocol LocalNotificationScheduling: Sendable {
    func schedule(_ presentation: PushPresentation, identifier: String) async
    /// `delay` is the seconds until the OS shows it (Demo: lets the user lock the phone first). Recorders ignore it.
    func schedule(_ presentation: PushPresentation, identifier: String, delay: TimeInterval) async
    func removeDelivered(identifiers: [String]) async
}

public extension LocalNotificationScheduling {
    func schedule(_ presentation: PushPresentation, identifier: String, delay: TimeInterval) async {
        await schedule(presentation, identifier: identifier)
    }
}

/// Demo and local simulation (decision A12): the SAME `PushProcessor` and `PushPresentation` the notification extension
/// uses, fed with sealed push bytes as FakeHost produces them, ending in a LOCAL notification that is labelled as
/// simulated. It is never evidence that the extension ran or that APNs delivered anything (diagnostics say
/// "local notification simulation"). In-memory replay state, per workspace, like the extension's but not persisted.
public actor PushSimulator {
    public struct Result: Equatable, Sendable {
        public let presentation: PushPresentation
        public let outcome: NSEMarker.Outcome
    }

    public static let label = "Simulated, local notification"
    private var keys: PushProcessor.Keyring
    private var names: [ID16: String]
    private var replay = PushProcessor.ReplayState()
    private let scheduler: any LocalNotificationScheduling
    private let now: @Sendable () -> Date

    private let delay: TimeInterval

    public init(materials: [ID16: PushMaterial], scheduler: any LocalNotificationScheduling, delay: TimeInterval = 1,
                now: @escaping @Sendable () -> Date = { Date() }) {
        keys = materials.mapValues(\.keys); names = materials.mapValues(\.name)
        self.scheduler = scheduler; self.now = now; self.delay = delay
    }

    /// `sealed` is the outer object (the bytes of the `o` string). Drops schedule the generic text, like the extension.
    @discardableResult
    public func simulate(sealed: Data) async -> Result {
        let nowMs = Int64((now().timeIntervalSince1970 * 1000).rounded())
        let out = PushProcessor.process(outer: sealed, keys: keys, replay: replay, nowMs: nowMs)
        replay = out.replay
        let result: Result
        switch out.result {
        case .show(let p):
            result = Result(presentation: .make(p, workspaceName: names[p.workspace] ?? "", simulated: true), outcome: .init(shown: p))
        case .drop(let why):
            result = Result(presentation: .genericSimulated, outcome: .init(drop: why))
        }
        if let key = result.presentation.removesDelivered { await scheduler.removeDelivered(identifiers: ["sim/\(key)"]) }
        await scheduler.schedule(result.presentation, identifier: "sim/\(result.presentation.entityKey ?? UUID().uuidString)", delay: delay)
        return result
    }
}

extension PushPresentation {
    static let genericSimulated = PushPresentation(style: .generic, title: genericTitle, body: genericBody, threadID: nil, entityKey: nil,
                                                   removesDelivered: nil, sound: false, simulated: true)
}

#if canImport(UserNotifications)
/// Schedules through `UNUserNotificationCenter`. The simulated flag becomes a visible subtitle and a `userInfo` marker.
public struct UNUserNotificationScheduler: LocalNotificationScheduling {
    public init() {}
    /// The last `add` failure text (nil after a success), so the app can show it instead of a silent no-op.
    public static let lastError = LastError()
    public final class LastError: @unchecked Sendable {
        private let lock = NSLock(); private var value: String?
        public func set(_ v: String?) { lock.lock(); value = v; lock.unlock() }
        public var current: String? { lock.lock(); defer { lock.unlock() }; return value }
    }
    public func schedule(_ p: PushPresentation, identifier: String) async {
        await schedule(p, identifier: identifier, delay: 1)
    }
    public func schedule(_ p: PushPresentation, identifier: String, delay: TimeInterval) async {
        let c = p.notificationContent()
        let req = UNNotificationRequest(identifier: identifier, content: c, trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false))
        // Completion-handler API (Xcode 16.4); a refusal is reported, not swallowed.
        let error: String? = await withCheckedContinuation { c in
            UNUserNotificationCenter.current().add(req) { c.resume(returning: $0.map { "\($0)" }) }
        }
        if let error { UNUserNotificationScheduler.lastError.set(error) } else { UNUserNotificationScheduler.lastError.set(nil) }
    }
    public func removeDelivered(identifiers: [String]) async {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}
#endif
