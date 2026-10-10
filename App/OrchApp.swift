import SwiftUI
import OrchUI

@main
struct OrchApp: App {
    private let options = LaunchOptions()

    var body: some Scene {
        WindowGroup {
            HomeScreen(options: options)
        }
    }
}
