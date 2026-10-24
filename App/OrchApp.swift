import SwiftUI

/// The app is the phone of a hub (V3, D69): it pairs with the hub only, never with a workspace. The hub flow (pair, home, sign) is the
/// root in every configuration; DEBUG adds launch arguments for the push harness and the in-process hub (UI tests, screenshots).
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
        HubRoot()
        #endif
    }
}
