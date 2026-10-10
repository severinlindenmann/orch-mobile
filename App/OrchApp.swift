import SwiftUI
import OrchUI

@main
struct OrchApp: App {
    private let options = LaunchOptions()

    var body: some Scene {
        WindowGroup {
            HomeScreen(options: options)
                .preferredColorScheme(options.appearance == "dark" ? .dark : options.appearance == "light" ? .light : nil)
        }
    }
}
