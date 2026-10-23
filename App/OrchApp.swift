import SwiftUI
import OrchUI

/// The app is the phone of a hub (V3, D69): it pairs with the hub only, never with a workspace. The hub screens are still DEBUG-only
/// while their design is open (mockup picks A4); a Release build shows `HubUnavailableView` until they ship.
@main
struct OrchApp: App {
    @UIApplicationDelegateAdaptor(OrchAppDelegate.self) private var delegate
    private let options = LaunchOptions()

    var body: some Scene {
        WindowGroup {
            root
                .preferredColorScheme(options.appearance == "dark" ? .dark : options.appearance == "light" ? .light : nil)
        }
    }

    @ViewBuilder private var root: some View {
        #if DEBUG
        if options.pushHarness { PushHarnessView(material: options.pushMaterial) }
        else if HubLaunch.model(arguments: ProcessInfo.processInfo.arguments, probe: true) { HubLaunchRoot() }
        else { HubRoot() }
        #else
        HubUnavailableView()
        #endif
    }
}

#if !DEBUG
/// Release placeholder: the hub screens are not shipped yet, and the app has no other pairing.
struct HubUnavailableView: View {
    var body: some View {
        VStack(spacing: OS.s4) {
            Image(systemName: "link.badge.plus").font(.system(size: 48)).foregroundStyle(OC.textMuted).accessibilityHidden(true)
            Text("orch needs your hub").font(OF.wsName).accessibilityAddTraits(.isHeader)
            Text("This iPhone pairs with your orch hub. Pairing arrives in an upcoming build.")
                .font(OF.body).foregroundStyle(OC.textMuted).multilineTextAlignment(.center)
        }
        .padding(OS.s5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OC.bg)
        .accessibilityIdentifier("app.hubunavailable")
    }
}
#endif
