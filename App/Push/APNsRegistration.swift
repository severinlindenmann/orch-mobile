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
    static func requestAfterFirstJoin(application: UIApplication = .shared) async -> State {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted { application.registerForRemoteNotifications() }
        return await current()
    }
}

final class OrchAppDelegate: NSObject, UIApplicationDelegate {
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
