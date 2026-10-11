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
        _bridge = State(initialValue: (services as? any ShareWorld).flatMap { ShareBridge.make(world: $0, publishDemo: options.shareDemoTargets) })
        _path = State(initialValue: initial.path)
        _forceWelcome = State(initialValue: initial.forceWelcome)
        _pairing = State(initialValue: initial.presentPairing
                         ? PairingPresentation(model: services.makePairing(start: initial.pairing)) : nil)
        self.initial = initial
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if forceWelcome || (services.home.workspaces.isEmpty && !services.home.isDemo) {
                    WelcomeScreen(onDemo: { services.home.enterDemo(); forceWelcome = false },
                                  onPair: { pairing = PairingPresentation(model: services.makePairing(start: nil)) })
                } else if services.home.workspaces.isEmpty {
                    EmptyHome(onPair: { pairing = PairingPresentation(model: services.makePairing(start: nil)) },
                              onSettings: { path.append(.settings) })
                } else {
                    HomeContent(services: services, path: $path)
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
                if services.home.isDemo {
                    ToolbarItem(placement: .topBarLeading) { DemoChip() }
                }
                if services.home.isDemo || !services.home.workspaces.isEmpty {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Add workspace", systemImage: "plus") {
                            pairing = PairingPresentation(model: services.makePairing(start: nil))
                        }
                        .accessibilityIdentifier("home.add")
                        Button("Settings", systemImage: "gearshape") { path.append(.settings) }
                            .accessibilityIdentifier("home.settings")
                    }
                }
            }
            .navigationDestination(for: Route.self) { route in
                RouteView(route: route, services: services, path: $path, composeDrop: initial.composeDrop)
            }
        }
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
    let services: any AppServices
    @Binding var path: [Route]

    private var home: any HomeModel { services.home }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OS.s3) {
                if home.needsYouCount > 0, let oldest = home.oldestWaiting { needsYouStrip(oldest) }
                ForEach(home.pendingDecisions) { d in pendingRow(d) }
                Text(verbatim: "Last checked \(Fmt.relative(home.lastChecked))")
                    .font(OF.meta).foregroundStyle(OC.textMuted)
                    .accessibilityIdentifier("home.lastChecked")
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

    private var stale: Bool { home.workspaces.contains { !$0.isLive } }

    private func needsYouStrip(_ oldest: (question: Question, workspace: WorkspaceInfo)) -> some View {
        let count = home.needsYouCount
        return NavigationLink(value: Route.needsYou) {
            HStack(spacing: OS.s3) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(OC.youMark)
                VStack(alignment: .leading, spacing: OS.s1) {
                    Text(verbatim: (stale ? "Last known: " : "") + (count == 1 ? "1 needs you" : "\(count) need you"))
                        .font(OF.section).foregroundStyle(OC.you)
                    Text(verbatim: "\(oldest.workspace.displayName) · \(oldest.question.firstLine)")
                        .font(OF.body).lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(OC.textMuted)
            }
            .padding(OS.s5)
            .orchCard()
            .overlay(alignment: .leading) { AttentionRail().padding(.leading, OS.s2).padding(.vertical, OS.s3) }
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
                Image(systemName: "chevron.right").foregroundStyle(OC.textMuted)
            }
            .padding(OS.s5).orchCard()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.pending")
    }

    private var dropCard: some View {
        NavigationLink(value: Route.drop) {
            HStack(spacing: OS.s3) {
                Image(systemName: "tray.and.arrow.down").foregroundStyle(OC.brand)
                VStack(alignment: .leading, spacing: OS.s1) {
                    Text("Drop").font(OF.section)
                    Text(verbatim: dropLine).font(OF.meta).foregroundStyle(OC.textMuted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(OC.textMuted)
            }
            .padding(OS.s5)
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
        HStack(spacing: OS.s3) {
            WorkspaceRail(color: ws.color)
            VStack(alignment: .leading, spacing: OS.s2) {
                if ws.isHosted { HostedMarker(hostedBy: ws.hostedBy) }
                Text(verbatim: ws.displayName).font(OF.wsName)
                Label { Text(verbatim: ws.displayHost) } icon: { Image(systemName: "laptopcomputer") }
                    .font(OF.meta).foregroundStyle(OC.textMuted)
                HStack(spacing: OS.s2) {
                    if waiting > 0 {
                        AttentionRail().frame(height: 22)
                        Label { Text(verbatim: (ws.isLive ? "" : "Last known: ") + Fmt.plural(waiting, "question waiting", "questions waiting")) }
                            icon: { Image(systemName: "questionmark.bubble") }
                            .font(OF.meta).foregroundStyle(OC.you)
                    } else {
                        Label { Text(verbatim: ws.isLive ? "Nothing needs you" : "Last known: nothing needs you") }
                            icon: { Image(systemName: "checkmark.circle") }
                            .font(OF.meta).foregroundStyle(OC.textMuted)
                    }
                }
                ConnectionChip(state: ws.connection)
                if let message = ws.lifecycle.message { Text(verbatim: message).font(OF.meta).foregroundStyle(OC.textMuted) }
            }
            .padding(.vertical, OS.s5)
            .padding(.trailing, OS.s5)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .orchCard()
        .clipShape(RoundedRectangle(cornerRadius: OR.card, style: .continuous))
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
                        WorkspaceRail(color: group.workspace.color).frame(height: 14).clipShape(Capsule())
                        Text(verbatim: group.workspace.displayName).font(OF.section)
                        if group.workspace.isHosted { Image(systemName: "building.2").foregroundStyle(OC.hosted)
                            .accessibilityLabel("Client hosted") }
                    }
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
        .navigationTitle("Needs you")
        .accessibilityIdentifier("needsYou.list")
    }
}

struct QuestionRow: View {
    let question: Question
    let color: Color
    let workspaceName: String

    var body: some View {
        HStack(spacing: OS.s3) {
            WorkspaceRail(color: color).frame(height: 36).clipShape(Capsule())
            VStack(alignment: .leading, spacing: OS.s1) {
                Text(verbatim: question.firstLine).lineLimit(2)
                Text(verbatim: "\(question.displayTicket) · \(workspaceName) · \(Fmt.relative(question.created))")
                    .font(OF.meta).foregroundStyle(OC.textMuted)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
