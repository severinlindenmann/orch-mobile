#if DEBUG
import OrchCustody
import OrchPush
import OrchProtocol
import SwiftUI
import UserNotifications

/// DEBUG-only test harness (`--push-harness`), never compiled into Release. It installs a TEST hub push material item into
/// the real `.push` keychain group, then shows the evidence the notification extension left behind: its invocation
/// marker (counter, outcome, timestamp: no decrypted content) and the titles/bodies of the notifications the OS actually delivered. It never displays decrypted push content
/// itself and writes nothing to disk but the keychain item.
struct PushHarnessView: View {
    let material: String?
    @State private var status = "starting"
    @State private var marker = "none"
    @State private var delivered = ""
    @State private var auth = "auth: ?"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("push harness").font(.headline)
            Text(status).accessibilityIdentifier("push.status")
            Text(marker).accessibilityIdentifier("push.marker")
            Text(delivered).accessibilityIdentifier("push.delivered")
            Text(auth).accessibilityIdentifier("push.auth")
            Button("Refresh") { Task { await refresh() } }.accessibilityIdentifier("push.refresh")
        }
        .padding()
        .task { await install(); await refresh() }
    }

    @MainActor
    private func install() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        UIApplication.shared.registerForRemoteNotifications()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        if let material, material.hasPrefix("hub:") { installHub(String(material.dropFirst(4))); return }
        status = "no or bad material"
    }

    /// A hub push material item (design B4) written to the real `.push` group, with the hub replay state cleared: the extension must open the
    /// hub pushes of the fixture with this push key only.
    @MainActor
    private func installHub(_ b64u: String) {
        guard let json = B64U.decode(b64u), let decoded = try? HubPushMaterial.decode(json), let ch = ID16(hex: decoded.channelID) else { status = "no or bad hub material"; return }
        guard let backend = KeychainBackend.fromBundle() else { status = "no keychain prefix"; return }
        do {
            let item = try SecretID(realm: .live, purpose: HubPushMaterial.purpose)
            try SecretVault(group: .push, backend: backend).put(json, for: item)
            if let dir = PushGroup.pushDir() {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(NSEMarker.fileName))
                try? FileManager.default.removeItem(at: HubPushIntake(pushDir: dir).stateDirectory(channelID: ch))
            }
            status = "material installed hub"
        } catch { status = "install failed: \(error)" }
    }

    @MainActor
    private func refresh() async {
        guard let dir = PushGroup.pushDir() else { marker = "marker: no app group"; return }
        if let m = NSEMarker.read(pushDir: dir) { marker = "marker: count=\(m.count) outcome=\(m.outcome.rawValue)" } else { marker = "marker: none" }
        // Completion-handler APIs map to Sendable values inside the callback (older SDKs flag the async variants).
        let status: Int = await withCheckedContinuation { c in
            UNUserNotificationCenter.current().getNotificationSettings { c.resume(returning: $0.authorizationStatus.rawValue) }
        }
        auth = "auth: \(status) (2=authorized)"
        let d: [String] = await withCheckedContinuation { c in
            UNUserNotificationCenter.current().getDeliveredNotifications { ns in
                c.resume(returning: ns.map { "[\($0.request.content.title)|\($0.request.content.body)|thread=\($0.request.content.threadIdentifier)]" })
            }
        }
        delivered = "delivered: " + d.sorted().joined(separator: ",")
    }
}
#endif
