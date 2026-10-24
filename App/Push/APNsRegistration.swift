import Foundation
import OrchClient
import OrchProtocol
import OrchPush
import Observation
import UIKit
import UserNotifications

/// The relay needs the APNs environment per registration (protocol-v2 19.10). It comes from how THIS build is signed (the
/// `aps-environment` of its provisioning profile), never from the build configuration: a Release build installed from Xcode carries a
/// development profile and gets sandbox tokens, a TestFlight or App Store build has no profile and gets production tokens (even against the
/// dev relay, D48). The Simulator has no usable environment (nil): it never registers.
typealias APNsEnvironment = PushEnvironment

extension PushEnvironment {
    /// Resolved once per process: the signing cannot change while the app runs. An absent profile file is a TestFlight/App Store build
    /// (production); a file that exists but cannot be read or parsed is unknown (nil), never "production by default".
    static let current: PushEnvironment? = {
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        let source: ProfileSource
        if let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") {
            source = (try? Data(contentsOf: URL(fileURLWithPath: path))).map { .data($0) } ?? .unreadable
        } else { source = .absent }
        return resolve(profile: source, isSimulator: simulator)
    }()
}

/// The APNs device token and its environment, stored once per installation (the hub channel registers it with the relay). It is an address that lets whoever holds the relay's APNs key reach this
/// device, so it is kept in a file in Application Support: excluded from backups, not in `UserDefaults` (which backs up and syncs to a
/// restored device, where the token is not valid), protected until first unlock. Leaving the hub / Reset does not need to remove it: iOS issues
/// a fresh token when the app registers again, and APNs rejects the stale one.
struct APNsTokenStore {
    struct Stored: Equatable, Sendable, Codable {
        /// base64url, as the register body carries it (`token`).
        let token: String
        let environment: APNsEnvironment
    }
    private let url: URL
    private static let legacyKeys = ["orch.apns.token", "orch.apns.env"]

    init(url: URL = APNsTokenStore.defaultURL, legacyDefaults: UserDefaults? = .standard) {
        self.url = url
        // The first version kept it in UserDefaults (backed up): drop that copy.
        for k in Self.legacyKeys { legacyDefaults?.removeObject(forKey: k) }
    }

    static var defaultURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("apns-token.json")
    }

    var stored: Stored? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    /// Returns true when the token or environment changed.
    @discardableResult
    func save(deviceToken: Data, environment: APNsEnvironment) -> Bool {
        let next = Stored(token: B64U.encode(deviceToken), environment: environment)
        guard next != stored, let data = try? JSONEncoder().encode(next) else { return false }
        var target = url
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try target.setResourceValues(values)
        } catch { return false }
        return true
    }

    func clear() { try? FileManager.default.removeItem(at: url) }
}

/// Permission and registration plumbing. The hub push driver reads `APNsTokenStore.stored` and registers it with the hub's relay channel.
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
        // The Simulator (or a build without a push entitlement) has no APNs environment: nothing to register, nothing to send the relay.
        guard APNsEnvironment.current != nil else { OrchAppDelegate.lastRegistrationError = "No APNs environment in this build (Simulator)"; return }
        OrchAppDelegate.registrationAttempted = true
        application.registerForRemoteNotifications()
    }

    /// Opens this app's page in iOS Settings (the only way back after a denial).
    static func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
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
        // A hub push: read the channel's mailbox now. The notification itself is the extension's verified, generic text.
        await MainActor.run { HubPushDriver.shared.pushArrived() }
        return [.banner, .list, .sound]
    }

    nonisolated(unsafe) static var lastRegistrationError: String?

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let store = APNsTokenStore()
        guard let environment = APNsEnvironment.current else { return }
        store.save(deviceToken: deviceToken, environment: environment)
        Task { @MainActor in await HubPushDriver.shared.registerPush() }   // the hub channel's target follows the token
        Self.lastRegistrationError = nil
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Visible state only (settings); never a crash, never retried in a tight loop.
        Self.lastRegistrationError = (error as NSError).localizedDescription
    }
}
