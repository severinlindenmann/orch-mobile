import SwiftUI
import OrchUI

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
        if options.pushHarness { PushHarnessView(material: options.pushMaterial) } else { HomeScreen(options: options) }
        #else
        HomeScreen(options: options)
        #endif
    }
}
