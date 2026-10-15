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

    #if DEBUG
    private static func shareStatusKind(_ route: String?) -> ShareProblemView.Kind? {
        switch route {
        case "share-status/unreadable": .unreadable
        case "share-status/none": .noWorkspaces
        default: nil
        }
    }
    #endif

    @ViewBuilder private var root: some View {
        #if DEBUG
        if options.pushHarness { PushHarnessView(material: options.pushMaterial) }
        else if let kind = Self.shareStatusKind(options.initialRoute) { ShareStatusPreview(kind: kind) }
        else if options.uiPreview { HomeScreen(services: PreviewWorld(demo: options.demo), options: options) }
        else { AppRoot(options: options) }
        #else
        AppRoot(options: options)
        #endif
    }
}

/// Starts the real service layer through the `RealmController`, then shows Home. Nothing is drawn from it before it is ready, so a debug
/// route resolves against real data. A realm transition replaces the whole Home view graph (`epoch`), including navigation and sheets.
struct AppRoot: View {
    let options: LaunchOptions
    @State private var realm: RealmController
    /// Parsed exactly once, after boot: a route's side effects (e.g. the Demo sign outcome) must not repeat on every body pass.
    @State private var initial: InitialRoute?

    init(options: LaunchOptions) {
        self.options = options
        _realm = State(initialValue: RealmController(options: options))
    }

    var body: some View {
        Group {
            if realm.booted, let initial, realm.state != .leaving, realm.state != .starting {
                // Only the first realm gets the launch route; a realm entered later starts at its own Home.
                HomeScreen(services: realm.services, options: options, initial: realm.epoch == 0 ? initial : InitialRoute())
                    .id(realm.epoch)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(OC.bg)
                    .accessibilityIdentifier("app.starting")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let notice = realm.notice {
                Text(notice).font(.footnote).padding(8).frame(maxWidth: .infinity).background(OC.bg)
                    .accessibilityIdentifier("realm.notice")
            }
        }
        .task {
            await realm.boot()
            if initial == nil { initial = InitialRouteParser.parse(options.initialRoute, services: realm.services) }
        }
    }
}
