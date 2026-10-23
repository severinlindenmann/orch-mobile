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
        else if HubLaunch.model(arguments: ProcessInfo.processInfo.arguments, probe: true) { HubLaunchRoot() }
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
    /// Scan, paste and `orch://` opens: every one lands on a review screen. Owned here so it outlives the realm's view graph.
    @State private var intake: LiveIntake
    @Environment(\.scenePhase) private var scenePhase
    /// Parsed exactly once, after boot: a route's side effects (e.g. the Demo sign outcome) must not repeat on every body pass.
    @State private var initial: InitialRoute?
    #if DEBUG
    /// An opened `orch://hub-pair/...` link (V3 dev): the hub pairing screen, never the workspace intake.
    @State private var hubPairing: HubPairingModel?
    #endif

    init(options: LaunchOptions) {
        self.options = options
        let controller = RealmController(options: options)
        _realm = State(initialValue: controller)
        _intake = State(initialValue: LiveIntake(realm: controller))
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
        .environment(intake)
        // Cold launch included: the intake holds an early URL until the realm has booted, then classifies it.
        .onOpenURL { url in
            #if DEBUG
            if HubLaunch.isHubLink(url.absoluteString) { hubPairing = HubLaunch.model(link: url.absoluteString); return }
            #endif
            intake.handle(url: url)
        }
        #if DEBUG
        .sheet(item: $hubPairing) { HubPairingScreen(model: $0) }
        #endif
        // Scene and protected-data lifecycle ownership: workspaces and the pairing on screen pause in the background, codes hide.
        .onChange(of: scenePhase) { _, phase in
            // C2b: `.inactive` ends every answer's eligibility for an automatic re-sign before anything else runs
            if phase == .inactive { realm.services.noteInactive() }
            realm.services.setActive(phase == .active)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            realm.services.noteProtectedDataUnavailable()
        }
        .fullScreenCover(isPresented: Binding(get: { realm.booted && intake.isPresented }, set: { if !$0 { intake.dismiss() } })) {
            LiveEntryFlow(intake: intake)
        }
        .task {
            await realm.boot()
            intake.realmBooted()
            #if DEBUG
            if let url = options.openURL {
                if HubLaunch.isHubLink(url) { hubPairing = HubLaunch.model(link: url) } else { intake.handle(text: url, source: .otherApp) }
            }
            #endif
            if initial == nil { initial = InitialRouteParser.parse(options.initialRoute, services: realm.services) }
        }
    }
}
