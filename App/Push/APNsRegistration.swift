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

/// The APNs device token and its environment, stored once per installation (the same token serves every workspace; the per-workspace
/// relay registration ids live in the workspace stores). It is an address that lets whoever holds the relay's APNs key reach this
/// device, so it is kept in a file in Application Support: excluded from backups, not in `UserDefaults` (which backs up and syncs to a
/// restored device, where the token is not valid), protected until first unlock. Leave Live / Reset does not need to remove it: iOS issues
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

/// Plain-text state for the Settings diagnostics row: nothing secret (no token value).
@MainActor
enum PushDiagnostics {
    static func summary(isDemo: Bool, permission: String, relay: String? = nil) -> String {
        let store = APNsTokenStore()
        var parts = ["permission: \(permission)", "APNs environment: \(APNsEnvironment.current?.rawValue ?? "none")"]
        if isDemo { parts.append("APNs: not used in Demo (local simulation only)") }
        else if let error = OrchAppDelegate.lastRegistrationError { parts.append("APNs registration failed: \(error)") }
        else if store.stored != nil { parts.append("APNs token registered") }
        else if OrchAppDelegate.registrationAttempted { parts.append("APNs registration pending") }
        else { parts.append("APNs registration not attempted") }
        if let relay, !isDemo { parts.append(relay) }
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
        #if DEBUG
        // A hub push (V3 dev): read the channel's mailbox now. The notification itself is the extension's verified, generic text.
        await MainActor.run { HubRuntime.shared.pushArrived() }
        #endif
        return [.banner, .list, .sound]
    }

    /// B10: a tap on the notification of an approval request (`ticket.update` with a `ph_` id) opens the approvals list. Only that one is
    /// routed; every other notification keeps today's behaviour. The key comes from the notification the extension built from a verified
    /// push, and the route carries no id: the list is read from the host.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let key = response.notification.request.content.userInfo[PushPresentation.keyInfo] as? String
        guard case .approvals = PushRouting.route(entityKey: key) else { return }
        await MainActor.run { PushRouteInbox.shared.openApprovals() }
    }

    /// Set by the session layer: called with the stored token EVERY time iOS hands one over (each launch that registers), changed or not,
    /// so the relay registration is refreshed at every launch and moves with a new token (the relay call is idempotent for the same token).
    nonisolated(unsafe) static var onTokenReceived: (@Sendable (APNsTokenStore.Stored) -> Void)?
    nonisolated(unsafe) static var lastRegistrationError: String?

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let store = APNsTokenStore()
        guard let environment = APNsEnvironment.current else { return }
        store.save(deviceToken: deviceToken, environment: environment)
        if let s = store.stored { Self.onTokenReceived?(s) }
        #if DEBUG
        Task { @MainActor in await HubRuntime.shared.registerPush() }   // the hub channel's target follows the token (V3 dev)
        #endif
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
    /// Survives relaunch: set when a boot failed or a reset is incomplete (the index could not be read), cleared ONLY by a
    /// successful rebuild from the index. While set, nothing is presented even when no runtime is wanted.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard
    static let unrebuiltKey = "orch.presentationGate.unrebuilt"
    static var persistedUnrebuilt: Bool { defaults.bool(forKey: unrebuiltKey) }
    static func requireRebuild() { defaults.set(true, forKey: unrebuiltKey); markNotRebuilt() }
    /// No index exists to read (no runtime wanted): open the gate, unless an earlier failure still requires a real rebuild.
    static func openWithoutIndex() { if !persistedUnrebuilt { markRebuilt() } }
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
        defaults.removeObject(forKey: unrebuiltKey)
        markRebuilt()
    }
    static func isBlocked(thread: String, identifier: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if !rebuilt { return true }
        return blocked.contains { $0 == thread || identifier.hasPrefix("demo/\($0)/") }
    }
}


/// Where a notification tap leaves its route until the Home screen takes it (it may not exist yet at launch).
@MainActor @Observable
final class PushRouteInbox {
    static let shared = PushRouteInbox()
    private(set) var approvalsRequested = 0
    private var taken = 0
    func openApprovals() { approvalsRequested += 1 }
    /// True once per request.
    func takeApprovals() -> Bool {
        guard approvalsRequested > taken else { return false }
        taken = approvalsRequested
        return true
    }
}
