import SwiftUI
import OrchUI

/// Root of the app: Welcome (nothing yet), empty Home (Demo, no workspaces) or Home (U1/U3).
struct HomeScreen: View {
    private let services: any AppServices
    @State private var path: [Route]
    @State private var pairing: PairingPresentation?
    @State private var forceWelcome: Bool
    @State private var bridge: ShareBridge?
    @Environment(\.scenePhase) private var scenePhase
    private let initial: InitialRoute
    private let options: LaunchOptions
    @Environment(\.colorScheme) private var scheme

    /// `initial` is the route parsed once by the caller; parsing here would re-apply its side effects (a Demo sign outcome) every time a
    /// parent body re-evaluates and recreates this view.
    init(services: any AppServices, options: LaunchOptions, initial parsed: InitialRoute? = nil) {
        let initial = parsed ?? InitialRouteParser.parse(options.initialRoute, services: services)
        self.services = services
        self.options = options
        _bridge = State(initialValue: (services as? any ShareWorld).flatMap { ShareBridge.make(world: $0) })
        // A deep link to a tab root (drop, settings, needs-you) is held back and applied to its tab once the tab bar exists, so the
        // screen (and e.g. a confirm alert it presents on appear) is never created twice, first on Home and then in its tab.
        let isTabRoot: Bool = switch initial.path.first { case .drop?, .settings?, .needsYou?: true; default: false }
        _path = State(initialValue: isTabRoot ? [] : initial.path)
        _pendingRoute = State(initialValue: isTabRoot ? initial.path : [])
        _forceWelcome = State(initialValue: initial.forceWelcome)
        _pairing = State(initialValue: initial.presentPairing
                         ? PairingPresentation(model: services.makePairing(start: initial.pairing)) : nil)
        self.initial = initial
    }

    @State private var tab: AppTab = .home
    @State private var questionsPath: [Route] = []
    @State private var dropPath: [Route] = []
    @State private var settingsPath: [Route] = []
    @State private var composeOnDropTab = false
    @State private var pendingRoute: [Route]
    @State private var routeOnHome = false

    /// With tabs, Drop / Settings / Questions are tabs, never a second copy pushed on Home: switch tabs instead.
    private func select(_ route: Route) {
        switch route {
        case .drop: dropPath = []; tab = .drop
        case .settings: settingsPath = []; tab = .settings
        case .needsYou: questionsPath = []; tab = .questions
        default: break
        }
    }

    /// Tabs exist once there is something to navigate (workspaces); Welcome and the empty Home stay a single stack.
    private var showsTabs: Bool {
        !(forceWelcome || (services.home.workspaces.isEmpty && !services.home.isDemo)) && !services.home.workspaces.isEmpty
    }

    /// Applies a held deep-link route to its tab once tabs exist. With no workspaces (empty Demo) there are never tabs for it, so the
    /// route is pushed on Home instead; if workspaces appear later it is moved to its tab.
    private func adoptInitialRoute() {
        if !showsTabs {
            if !pendingRoute.isEmpty { path = pendingRoute; pendingRoute = []; routeOnHome = true }
            return
        }
        let source: [Route]
        if !pendingRoute.isEmpty { source = pendingRoute; pendingRoute = [] }
        else if routeOnHome { source = path; path = [] }
        else { return }
        routeOnHome = false
        guard let first = source.first else { return }
        let rest = Array(source.dropFirst())
        switch first {
        case .drop: dropPath = rest; composeOnDropTab = initial.composeDrop; tab = .drop
        case .settings: settingsPath = rest; tab = .settings
        case .needsYou: questionsPath = rest; tab = .questions
        default: path = source
        }
    }

    private func startPairing() { pairing = PairingPresentation(model: services.makePairing(start: nil)) }

    private var homeStack: some View {
        NavigationStack(path: $path) {
            Group {
                if forceWelcome || (services.home.workspaces.isEmpty && !services.home.isDemo) {
                    WelcomeScreen(onDemo: { services.home.enterDemo(); forceWelcome = false }, onPair: startPairing)
                } else if services.home.workspaces.isEmpty {
                    EmptyHome(onPair: startPairing, onSettings: { path.append(.settings) })
                } else {
                    HomeContent(services: services, path: $path, onAdd: startPairing)
                }
            }
            .safeAreaInset(edge: .top) {
                if let live = services as? LiveServices, live.resetIncomplete {
                    VStack(spacing: 4) {
                        Text("Reset incomplete — will finish on next launch")
                        Button("Try again") { live.resetThisiPhone() }
                    }
                    .font(.footnote)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(OC.bg)
                    .accessibilityIdentifier("home.resetIncomplete")
                }
            }
            .background(OC.bg)
            .navigationTitle("orch")
            .toolbar {
                if services.home.isDemo && services.home.workspaces.isEmpty {
                    ToolbarItem(placement: .topBarLeading) { DemoChip() }
                }
                if services.home.isDemo && services.home.workspaces.isEmpty {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Add workspace", systemImage: "plus", action: startPairing)
                            .accessibilityIdentifier("home.add")
                    }
                }
            }
            .toolbar(services.home.workspaces.isEmpty ? .visible : .hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                RouteView(route: route, services: services, path: $path, composeDrop: initial.composeDrop)
            }
        }
    }

    private func tabStack<Root: View>(_ binding: Binding<[Route]>, @ViewBuilder root: () -> Root) -> some View {
        NavigationStack(path: binding) {
            root()
                .navigationDestination(for: Route.self) { route in
                    RouteView(route: route, services: services, path: binding, composeDrop: false)
                }
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        if showsTabs {
            TabView(selection: $tab) {
                homeStack
                    .tabItem { Label("Home", systemImage: "house") }
                    .tag(AppTab.home)
                tabStack($questionsPath) { NeedsYouScreen(services: services) }
                    .tabItem { Label("Questions", systemImage: "questionmark.bubble") }
                    .badge(services.home.needsYouCount)
                    .tag(AppTab.questions)
                tabStack($dropPath) { DropScreen(services: services, startComposing: composeOnDropTab) }
                    .tabItem { Label("Drop", systemImage: "tray.and.arrow.down") }
                    .tag(AppTab.drop)
                tabStack($settingsPath) { SettingsScreen(services: services, path: $settingsPath) }
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(AppTab.settings)
            }
        } else {
            homeStack
        }
    }

    var body: some View {
        rootContent
        .environment(\.routeSelector, showsTabs ? RouteSelector({ select($0) }, goHome: { tab = .home }) : nil)
        .onAppear { adoptInitialRoute() }
        .onChange(of: showsTabs) { _, _ in adoptInitialRoute() }
        .tint(OC.brand)
        // A10: claim what the share extension staged, on launch and on every activation.
        .task {
            #if DEBUG
            if options.seedShareQuarantine { bridge?.seedQuarantinedJobForUITests() }
            #endif
            if options.holdShareImport { bridge?.publishTargets() } else { bridge?.refresh() }
        }
        .onChange(of: scenePhase) { _, phase in
            (services as? LiveServices)?.setActive(phase == .active)
            if phase == .active { if options.holdShareImport { bridge?.publishTargets() } else { bridge?.refresh() } }
        }
        .onChange(of: services.home.workspaces) { _, _ in bridge?.publishTargets() }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .orchDebugShareRefresh)) { _ in bridge?.refresh() }
        #endif
        .symbolRenderingMode(.hierarchical)
        .safeAreaInset(edge: .top, spacing: 0) { if services.home.isDemo { DemoStripe() } }
        .overlay(alignment: .topLeading) {
            // DEBUG/UI-test only: lets tests assert the resolved colour scheme.
            if options.uiTesting {
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityElement().accessibilityIdentifier("debug.scheme")
                    .accessibilityValue(scheme == .dark ? "dark" : "light")
            }
        }
        .fullScreenCover(item: $pairing) { presentation in
            PairingScreen(model: presentation.model, onClose: { pairing = nil })
                .tint(OC.brand)
        }
    }
}

struct PairingPresentation: Identifiable {
    let id = UUID()
    let model: any PairingFlowModel
}

private struct RouteView: View {
    let route: Route
    let services: any AppServices
    @Binding var path: [Route]
    let composeDrop: Bool

    var body: some View {
        switch route {
        case .needsYou: NeedsYouScreen(services: services)
        case .workspace(let id, let segment): WorkspaceScreen(services: services, workspaceID: id, segment: segment)
        case .question(let ws, let id, let autoSign):
            QuestionScreen(services: services, workspaceID: ws, questionID: id, autoSign: autoSign)
        case .ticket(let ws, let key): TicketScreen(services: services, workspaceID: ws, key: key)
        case .drop: DropScreen(services: services, startComposing: composeDrop)
        case .dropItem(let id): DropItemScreen(services: services, itemID: id)
        case .shareFixture:
            #if DEBUG
            ShareFixtureScreen(openDrop: { path.append(.drop) })
            #else
            EmptyView()
            #endif
        case .settings: SettingsScreen(services: services, path: $path)
        case .workspaceSettings(let id, let leave):
            WorkspaceSettingsScreen(services: services, workspaceID: id, confirmLeave: leave, path: $path)
        }
    }
}

// MARK: Welcome / empty

struct WelcomeScreen: View {
    let onDemo: () -> Void
    let onPair: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: OS.s5) {
                Image(systemName: "square.stack.3d.up").font(OF.display).foregroundStyle(OC.brand)
                    .accessibilityHidden(true).padding(.top, OS.s8)
                Text("Welcome to orch").font(OF.display).multilineTextAlignment(.center)
                Text("Answer your workspaces from your iPhone. Everything is end-to-end encrypted.")
                    .font(OF.body).multilineTextAlignment(.center).foregroundStyle(OC.textMuted)
                VStack(spacing: OS.s3) {
                    Button(action: onDemo) { Text("Try Demo") }
                        .buttonStyle(.orchProminent)
                        .accessibilityIdentifier("welcome.demo")
                    Button(action: onPair) { Text("Pair a workspace").frame(maxWidth: .infinity).padding(.vertical, OS.s2) }
                        .buttonStyle(.bordered).controlSize(.large)
                        .accessibilityIdentifier("welcome.pair")
                }
                Text("Demo uses made-up workspaces on this iPhone. Nothing leaves it.")
                    .font(OF.meta).foregroundStyle(OC.demo).multilineTextAlignment(.center)
                SimulationNotice()
            }
            .padding(OS.s5)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(OC.text)
    }
}

struct EmptyHome: View {
    let onPair: () -> Void
    let onSettings: () -> Void
    var body: some View {
        ScrollView {
            VStack(spacing: OS.s4) {
                EmptyState(systemImage: "tray", title: "No workspaces",
                           detail: "Pair one from orch on your Mac (Remote, then Pair phone).")
                Button(action: onPair) { Text("Pair a workspace") }.buttonStyle(.orchProminent)
                    .accessibilityIdentifier("empty.pair")
                Button(action: onSettings) { Text("Settings").frame(maxWidth: .infinity).padding(.vertical, OS.s2) }
                    .buttonStyle(.bordered).accessibilityIdentifier("empty.settings")
                SimulationNotice()
            }
            .padding(OS.s4)
        }
        .foregroundStyle(OC.text)
        .accessibilityIdentifier("home.empty")
    }
}

// MARK: Home content

struct HomeContent: View {
    @ScaledMetric(relativeTo: .body) private var iconBox = 36.0
    let services: any AppServices
    @Binding var path: [Route]
    let onAdd: () -> Void

    private var home: any HomeModel { services.home }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OS.s3) {
                header
                if home.needsYouCount > 0, let oldest = home.oldestWaiting { needsYouStrip(oldest) }
                ForEach(home.pendingDecisions) { d in pendingRow(d) }
                Text(verbatim: "Last checked \(Fmt.relative(home.lastChecked))")
                    .font(.footnote).foregroundStyle(OC.textFaint)
                    .padding(.horizontal, OS.s1).padding(.top, OS.s1)
                    .accessibilityIdentifier("home.lastChecked")
                SectionCaption("Your workspaces").padding(.horizontal, OS.s1)
                ForEach(home.workspaces) { ws in
                    NavigationLink(value: Route.workspace(ws.id, .questions)) {
                        WorkspaceCard(ws: ws, waiting: home.waitingCount(in: ws.id))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.workspace.\(ws.id)")
                }
                dropCard
                SimulationNotice()
            }
            .padding(OS.s4)
        }
        .foregroundStyle(OC.text)
    }

    private var header: some View {
        HStack(spacing: OS.s3) {
            OrbitMark(size: 30)
            Text("orch").font(OF.display).accessibilityAddTraits(.isHeader)
            if home.isDemo { DemoChip() }
            Spacer(minLength: 0)
            Button(action: onAdd) {
                Image(systemName: "plus").font(.title3.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .foregroundStyle(OC.brand)
            .accessibilityLabel("Add workspace")
            .accessibilityIdentifier("home.add")
        }
    }

    private var stale: Bool { home.workspaces.contains { !$0.isLive } }

    private func needsYouStrip(_ oldest: (question: Question, workspace: WorkspaceInfo)) -> some View {
        let count = home.needsYouCount
        return TabAwareLink(route: .needsYou) {
            HStack(spacing: OS.s3) {
                Image(systemName: "questionmark.bubble.fill").font(.body.weight(.semibold))
                    .foregroundStyle(OC.onBrand).frame(width: iconBox, height: iconBox)
                    .background(OC.brand, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: OS.s1) {
                    Text(verbatim: (stale ? "Last known: " : "") + (count == 1 ? "1 needs you" : "\(count) need you"))
                        .font(OF.section).foregroundStyle(OC.text)
                    Text(verbatim: "\(oldest.workspace.displayName) · \(oldest.question.firstLine)")
                        .font(OF.body).foregroundStyle(OC.textMuted).lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(OC.brand)
            }
            .padding(OS.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OC.soft(OC.brand), in: RoundedRectangle(cornerRadius: OR.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.needsYou")
        .accessibilityLabel(Text(verbatim: "\(stale ? "Last known: " : "")\(count) questions need you. Oldest: \(oldest.workspace.displayName), \(oldest.question.firstLine)"))
        .accessibilityHint("Opens the list of waiting questions")
    }

    private func pendingRow(_ d: DecisionStatus) -> some View {
        NavigationLink(value: Route.question(workspace: d.workspaceID, id: d.questionID, autoSign: false)) {
            HStack(spacing: OS.s3) {
                let retry = d.outcome == .needsRetry
                Image(systemName: retry ? "exclamationmark.arrow.circlepath" : "clock.arrow.circlepath").foregroundStyle(retry ? OC.warn : OC.info)
                VStack(alignment: .leading, spacing: OS.s1) {
                    Text(retry ? "Your answer was not delivered" : "Checking whether your answer was received")
                        .font(OF.section).foregroundStyle(retry ? OC.warn : OC.info)
                    Text(retry ? "Tap to send it again" : "Tap to see where it stands").font(OF.meta).foregroundStyle(OC.textMuted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(OC.textMuted)
            }
            .padding(OS.s4).orchCard()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.pending")
    }

    private var dropCard: some View {
        TabAwareLink(route: .drop) {
            HStack(spacing: OS.s3) {
                Image(systemName: "tray.and.arrow.down").foregroundStyle(OC.brand)
                VStack(alignment: .leading, spacing: OS.s1) {
                    Text("Drop").font(OF.section)
                    Text(verbatim: dropLine).font(OF.meta).foregroundStyle(OC.textMuted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(OC.textMuted)
            }
            .padding(OS.s4)
            .orchCard()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.drop")
    }

    private var dropLine: String {
        let s = home.dropSummary
        if s.newCount == 0 { return "Files and notes from your workspaces" }
        return Fmt.plural(s.newCount, "new file", "new files") + (s.lastName.map { " · " + SafeText.inline($0, limit: 40) } ?? "")
    }
}

struct WorkspaceCard: View {
    let ws: WorkspaceInfo
    let waiting: Int

    var body: some View {
        VStack(alignment: .leading, spacing: OS.s2) {
            HStack(alignment: .firstTextBaseline, spacing: OS.s2) {
                Image(systemName: "laptopcomputer").foregroundStyle(OC.textMuted).accessibilityHidden(true)
                Text(verbatim: ws.displayName).font(OF.wsName).frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: ws.displayHost).font(OF.meta).foregroundStyle(OC.textMuted)
            FlowLayout {
                ConnectionChip(state: ws.connection)
                if ws.isHosted { HostedMarker(hostedBy: ws.hostedBy) }
                if waiting > 0 {
                    StatusChip((ws.isLive ? "" : "Last known: ") + Fmt.plural(waiting, "question waiting", "questions waiting"),
                               systemImage: "questionmark.bubble", color: OC.brand)
                } else {
                    StatusChip(ws.isLive ? "Nothing needs you" : "Last known: nothing needs you",
                               systemImage: "checkmark.circle", color: OC.textMuted)
                }
            }
            if let message = ws.lifecycle.message { Text(verbatim: message).font(OF.meta).foregroundStyle(OC.textMuted) }
        }
        .padding(OS.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orchCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: label))
    }

    private var label: String {
        var parts = [ws.displayName]
        if ws.isHosted { parts.append(ws.hostedBy.map { "hosted by " + SafeText.inline($0, limit: 40) } ?? "hosted by unknown") }
        let prefix = ws.isLive ? "" : "last known: "
        parts.append(prefix + (waiting == 0 ? "nothing needs you" : "\(waiting) questions waiting"))
        switch ws.connection {
        case .online: parts.append("live")
        case .offline(let s): parts.append("offline as of \(Fmt.time(s))")
        case .reconciling: parts.append("reconnecting")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: Needs you

struct NeedsYouScreen: View {
    let services: any AppServices

    var body: some View {
        List {
            ForEach(services.home.needsYou) { group in
                Section {
                    ForEach(group.questions) { q in
                        NavigationLink(value: Route.question(workspace: group.workspace.id, id: q.id, autoSign: false)) {
                            QuestionRow(question: q, color: group.workspace.color, workspaceName: group.workspace.displayName)
                        }
                        .accessibilityIdentifier("question.\(q.id)")
                    }
                } header: {
                    HStack(spacing: OS.s2) {
                        Text(verbatim: group.workspace.displayName).font(OF.section).foregroundStyle(OC.text)
                        if group.workspace.isHosted { Image(systemName: "building.2").foregroundStyle(OC.hosted)
                            .accessibilityLabel("Client hosted") }
                    }
                    .textCase(nil)
                }
            }
            Section {
                Text(verbatim: "Last checked \(Fmt.relative(services.home.lastChecked))")
                    .font(OF.meta).foregroundStyle(OC.textMuted)
            }
            if services.home.needsYouCount == 0 {
                EmptyState(systemImage: "checkmark.seal", title: "Nothing needs you").listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(OC.bg)
        .navigationTitle("Questions")
        .accessibilityIdentifier("needsYou.list")
    }
}

struct QuestionRow: View {
    let question: Question
    let color: Color
    let workspaceName: String

    var body: some View {
        VStack(alignment: .leading, spacing: OS.s1) {
            Text(verbatim: question.firstLine).lineLimit(2)
            Text(verbatim: "\(question.displayTicket) · \(workspaceName) · \(Fmt.relative(question.created))")
                .font(OF.meta).foregroundStyle(OC.textMuted)
        }
        .accessibilityElement(children: .combine)
    }
}


enum AppTab: Hashable { case home, questions, drop, settings }

/// Set while the tab bar is shown: routes that are tab roots switch tab instead of pushing a duplicate screen.
struct RouteSelector: Sendable {
    let action: @MainActor @Sendable (Route) -> Void
    let goHome: @MainActor @Sendable () -> Void
    init(_ action: @escaping @MainActor @Sendable (Route) -> Void, goHome: @escaping @MainActor @Sendable () -> Void) {
        self.action = action; self.goHome = goHome
    }
}

private struct RouteSelectorKey: EnvironmentKey { static let defaultValue: RouteSelector? = nil }
extension EnvironmentValues {
    var routeSelector: RouteSelector? {
        get { self[RouteSelectorKey.self] }
        set { self[RouteSelectorKey.self] = newValue }
    }
}

/// A NavigationLink that, under the tab bar, selects the matching tab instead.
struct TabAwareLink<Label: View>: View {
    let route: Route
    @ViewBuilder let label: Label
    @Environment(\.routeSelector) private var selector

    var body: some View {
        if let selector {
            Button { selector.action(route) } label: { label }
        } else {
            NavigationLink(value: route) { label }
        }
    }
}
