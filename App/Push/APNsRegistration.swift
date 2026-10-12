import Foundation
import OrchProtocol
import UIKit
import UserNotifications

/// `sandbox` for Xcode installs, `production` for TestFlight and App Store builds (even against the dev relay, D48).
/// The relay needs it per registration (host-api v0 section 3, gap 15).
enum APNsEnvironment: String, Sendable {
    case sandbox, production
    static var current: APNsEnvironment {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }
}

/// The APNs device token, stored once per installation (it is the same for every workspace, so it is not tagged with
/// one; the per-workspace relay registration ids live with the session, wired later). Not a secret.
struct APNsTokenStore {
    struct Stored: Equatable, Sendable {
        /// base64url, as the register body carries it (`token`).
        let token: String
        let environment: APNsEnvironment
    }
    private let defaults: UserDefaults
    private static let tokenKey = "orch.apns.token", envKey = "orch.apns.env"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var stored: Stored? {
        guard let t = defaults.string(forKey: Self.tokenKey), let e = defaults.string(forKey: Self.envKey).flatMap(APNsEnvironment.init(rawValue:)) else { return nil }
        return Stored(token: t, environment: e)
    }

    /// Returns true when the token changed (callers re-register every workspace then).
    @discardableResult
    func save(deviceToken: Data, environment: APNsEnvironment = .current) -> Bool {
        let next = Stored(token: B64U.encode(deviceToken), environment: environment)
        guard next != stored else { return false }
        defaults.set(next.token, forKey: Self.tokenKey); defaults.set(environment.rawValue, forKey: Self.envKey)
        return true
    }

    func clear() { defaults.removeObject(forKey: Self.tokenKey); defaults.removeObject(forKey: Self.envKey) }
}

/// Permission and registration plumbing. Wired later: pairing calls `requestAfterFirstJoin()` once the first join is
/// verified (U10: never at launch), then sends `APNsTokenStore.stored` to the relay per workspace.
@MainActor
enum PushPermission {
    enum State: Equatable, Sendable { case notDetermined, denied, authorized, provisional }

    static func current() async -> State {
        // Completion-handler API: the raw status is Sendable (older SDKs flag the async variant).
        let raw: Int = await withCheckedContinuation { c in
            UNUserNotificationCenter.current().getNotificationSettings { c.resume(returning: $0.authorizationStatus.rawValue) }
        }
        return switch UNAuthorizationStatus(rawValue: raw) ?? .notDetermined {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .provisional, .ephemeral: .provisional
        default: .authorized
        }
    }

    /// Asks for permission (the system prompt appears at most once) and, if granted, registers with APNs. A denial is a
    /// visible state in settings, not an error.
    @discardableResult
    static func requestAfterFirstJoin(application: UIApplication = .shared, registerWithAPNs: Bool = true) async -> State {
        let granted = await requestAuthorization()
        if granted, registerWithAPNs { registerForAPNs(application: application) }
        return await current()
    }

    /// Shows the system prompt only while the status is undetermined (the OS never asks twice). Completion-handler API (Xcode 16.4).
    static func requestIfNeeded() async -> State {
        let state = await current()
        guard state == .notDetermined else { return state }
        _ = await requestAuthorization()
        return await current()
    }

    private static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { c in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if let error { OrchAppDelegate.lastRegistrationError = "Notification permission: \(error.localizedDescription)" }
                c.resume(returning: granted)
            }
        }
    }

    /// Real APNs registration: only for a real (non-Demo) installation that was granted permission. The outcome (token or
    /// failure) lands in `PushDiagnostics`, never silently.
    static func registerForAPNs(application: UIApplication = .shared) {
        OrchAppDelegate.registrationAttempted = true
        application.registerForRemoteNotifications()
    }

    /// Opens this app's page in iOS Settings (the only way back after a denial).
    static func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

/// Plain-text state for the Settings diagnostics row: nothing secret (no token value).
@MainActor
enum PushDiagnostics {
    static func summary(isDemo: Bool, permission: String) -> String {
        let store = APNsTokenStore()
        var parts = ["permission: \(permission)", "APNs environment: \(APNsEnvironment.current.rawValue)"]
        if isDemo { parts.append("APNs: not used in Demo (local simulation only)") }
        else if let error = OrchAppDelegate.lastRegistrationError { parts.append("APNs registration failed: \(error)") }
        else if store.stored != nil { parts.append("APNs token registered") }
        else if OrchAppDelegate.registrationAttempted { parts.append("APNs registration pending") }
        else { parts.append("APNs registration not attempted") }
        return parts.joined(separator: " · ")
    }
}

final class OrchAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    nonisolated(unsafe) static var registrationAttempted = false

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Without this iOS shows nothing while orch is in the foreground (the owner's "test notifications showed nothing").
    /// The async form: its signature is identical in the Xcode 16.4 and newer SDKs (the completion-handler form's
    /// Sendable annotation differs between them and fails to compile on CI).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // Defense in depth: nothing from a removed or quarantined workspace is shown, even if it was scheduled earlier.
        if PresentationGate.isBlocked(thread: notification.request.content.threadIdentifier, identifier: notification.request.identifier) {
            return []
        }
        return [.banner, .list, .sound]
    }

    /// Set by the session layer later: called with the token when it changed (re-register every workspace).
    nonisolated(unsafe) static var onTokenChanged: (@Sendable (APNsTokenStore.Stored) -> Void)?
    nonisolated(unsafe) static var lastRegistrationError: String?

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let store = APNsTokenStore()
        if store.save(deviceToken: deviceToken), let s = store.stored { Self.onTokenChanged?(s) }
        Self.lastRegistrationError = nil
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Visible state only (settings); never a crash, never retried in a tight loop.
        Self.lastRegistrationError = (error as NSError).localizedDescription
    }
}

/// Workspaces that are removed (Leave, reset) or quarantined; foreground presentation checks it. Thread-safe: read from the notification delegate.
enum PresentationGate {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var blocked: Set<String> = []
    /// False until a rebuild from the workspace index succeeded (or the app has no index at all). While false nothing is
    /// presented: a notification that arrives between launch and the rebuild, or after an unreadable index, is not shown.
    nonisolated(unsafe) private static var rebuilt = false
    static var isRebuilt: Bool { lock.lock(); defer { lock.unlock() }; return rebuilt }
    static func markRebuilt() { lock.lock(); rebuilt = true; lock.unlock() }
    static func markNotRebuilt() { lock.lock(); rebuilt = false; lock.unlock() }
    static func block(_ ws: String) { lock.lock(); blocked.insert(ws); lock.unlock() }
    static func unblock(_ ws: String) { lock.lock(); blocked.remove(ws); lock.unlock() }
    static func blockAll(_ ws: [String]) { lock.lock(); blocked.formUnion(ws); lock.unlock() }

    /// Realm-agnostic rebuild from a workspace index (the gate is memory-only). Fails closed: an unreadable index leaves the
    /// gate "not rebuilt" (blocks everything) until a later rebuild succeeds.
    @MainActor @discardableResult
    static func rebuild(reading read: () async throws -> (tombstones: [(ws: String, generation: Int64)], workspaces: [(ws: String, generation: Int64)])) async -> Bool {
        do {
            let r = try await read()
            rebuild(tombstones: r.tombstones, workspaces: r.workspaces)
            return true
        } catch { markNotRebuilt(); return false }
    }

    /// Blocks every tombstoned workspace, unless the index now lists that workspace at a newer generation (re-paired: a new
    /// membership). Only adds; Leave/reset/transition add live. Marks the gate rebuilt.
    static func rebuild(tombstones: [(ws: String, generation: Int64)], workspaces: [(ws: String, generation: Int64)]) {
        let current = Dictionary(workspaces.map { ($0.ws, $0.generation) }, uniquingKeysWith: max)
        let stale = tombstones.filter { t in (current[t.ws] ?? Int64.min) <= t.generation }.map(\.ws)
        blockAll(stale)
        markRebuilt()
    }
    static func isBlocked(thread: String, identifier: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if !rebuilt { return true }
        return blocked.contains { $0 == thread || identifier.hasPrefix("demo/\($0)/") }
    }
}
