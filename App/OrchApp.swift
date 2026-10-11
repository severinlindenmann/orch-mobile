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
        if options.pushHarness { PushHarnessView(material: options.pushMaterial) }
        else if options.uiPreview { HomeScreen(services: PreviewWorld(demo: options.demo), options: options) }
        else { AppRoot(options: options) }
        #else
        AppRoot(options: options)
        #endif
    }
}

/// Starts the real service layer, then shows Home. Nothing is drawn from it before it is ready, so a debug route resolves against real data.
struct AppRoot: View {
    let options: LaunchOptions
    @State private var services: LiveServices
    /// Parsed exactly once, after boot: a route's side effects (e.g. the Demo sign outcome) must not repeat on every body pass.
    @State private var initial: InitialRoute?

    init(options: LaunchOptions) {
        self.options = options
        _services = State(initialValue: LiveServices(options: options))
    }

    var body: some View {
        Group {
            if services.ready, let initial {
                HomeScreen(services: services, options: options, initial: initial)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(OC.bg)
                    .accessibilityIdentifier("app.starting")
            }
        }
        .task {
            await services.boot()
            if initial == nil { initial = InitialRouteParser.parse(options.initialRoute, services: services) }
        }
    }
}
