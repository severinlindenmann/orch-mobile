import SwiftUI
import OrchUI

/// Root of the app: Welcome (no workspaces) or Home (U1/U3), with the Demo stripe on every screen in Demo.
struct HomeScreen: View {
    @State private var world: PreviewWorld
    @State private var path: [Route]
    @State private var pairing: PairingPresentation?
    @State private var forceWelcome: Bool
    private let initial: InitialRoute

    init(options: LaunchOptions) {
        let world = PreviewWorld(demo: options.demo)
        let initial = InitialRouteParser.parse(options.initialRoute, services: world)
        _world = State(initialValue: world)
        _path = State(initialValue: initial.path)
        _forceWelcome = State(initialValue: initial.forceWelcome)
        _pairing = State(initialValue: initial.presentPairing
                         ? PairingPresentation(model: world.makePairing(start: initial.pairing)) : nil)
        self.initial = initial
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if world.workspaces.isEmpty || forceWelcome {
                    WelcomeScreen(home: world, onDemo: { world.enterDemo(); forceWelcome = false },
                                  onPair: { pairing = PairingPresentation(model: world.makePairing(start: nil)) })
                } else {
                    HomeContent(services: world, path: $path)
                }
            }
            .background(OC.bg)
            .navigationTitle("orch")
            .toolbar {
                if world.isDemo {
                    ToolbarItem(placement: .topBarLeading) { DemoChip() }
                }
                if !world.workspaces.isEmpty {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Add workspace", systemImage: "plus") {
                            pairing = PairingPresentation(model: world.makePairing(start: nil))
                        }
                        .accessibilityIdentifier("home.add")
                        Button("Settings", systemImage: "gearshape") { path.append(.settings) }
                            .accessibilityIdentifier("home.settings")
                    }
                }
            }
            .navigationDestination(for: Route.self) { route in
                RouteView(route: route, services: world, path: $path, composeDrop: initial.composeDrop)
            }
        }
        .tint(OC.brand)
        .symbolRenderingMode(.hierarchical)
        .safeAreaInset(edge: .top, spacing: 0) { if world.isDemo { DemoStripe() } }
        .fullScreenCover(item: $pairing) { presentation in
            PairingScreen(model: presentation.model, onClose: { pairing = nil })
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
        case .settings: SettingsScreen(services: services, path: $path)
        case .workspaceSettings(let id, let leave):
            WorkspaceSettingsScreen(services: services, workspaceID: id, confirmLeave: leave, path: $path)
        }
    }
}

// MARK: Welcome

struct WelcomeScreen: View {
    let home: any HomeModel
    let onDemo: () -> Void
    let onPair: () -> Void

    var body: some View {
        VStack(spacing: OS.s5) {
            Spacer()
            Image(systemName: "square.stack.3d.up").font(OF.display).foregroundStyle(OC.brand)
                .accessibilityHidden(true)
            Text("Welcome to orch").font(OF.display).multilineTextAlignment(.center)
            Text("Answer your workspaces from your iPhone. Everything is end-to-end encrypted.")
                .font(OF.body).multilineTextAlignment(.center).foregroundStyle(OC.textMuted)
            VStack(spacing: OS.s3) {
                Button(action: onDemo) { Text("Try Demo").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("welcome.demo")
                Button(action: onPair) { Text("Pair a workspace").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large)
                    .accessibilityIdentifier("welcome.pair")
            }
            Text("Demo uses made-up workspaces on this iPhone. Nothing leaves it.")
                .font(OF.meta).foregroundStyle(OC.demo).multilineTextAlignment(.center)
            Spacer()
        }
        .padding(OS.s5)
        .frame(maxWidth: .infinity)
        .foregroundStyle(OC.text)
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
                Text("Last checked \(Fmt.relative(home.lastChecked))")
                    .font(OF.meta).foregroundStyle(OC.textMuted)
                    .accessibilityIdentifier("home.lastChecked")
                ForEach(home.workspaces) { ws in
                    NavigationLink(value: Route.workspace(ws.id, .questions)) { WorkspaceCard(ws: ws, waiting: home.waitingCount(in: ws.id)) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("home.workspace.\(ws.id)")
                }
                dropCard
            }
            .padding(OS.s4)
        }
        .foregroundStyle(OC.text)
    }

    private func needsYouStrip(_ oldest: (question: Question, workspace: WorkspaceInfo)) -> some View {
        NavigationLink(value: Route.needsYou) {
            HStack(spacing: OS.s3) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(OC.youMark)
                VStack(alignment: .leading, spacing: OS.s1) {
                    Text(home.needsYouCount == 1 ? "1 needs you" : "\(home.needsYouCount) need you")
                        .font(OF.section).foregroundStyle(OC.you)
                    Text("\(oldest.workspace.name) · \(oldest.question.firstLine)")
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
        .accessibilityLabel("\(home.needsYouCount) questions need you. Oldest: \(oldest.workspace.name), \(oldest.question.firstLine)")
        .accessibilityHint("Opens the list of waiting questions")
    }

    private var dropCard: some View {
        NavigationLink(value: Route.drop) {
            HStack(spacing: OS.s3) {
                Image(systemName: "tray.and.arrow.down").foregroundStyle(OC.brand)
                VStack(alignment: .leading, spacing: OS.s1) {
                    Text("Drop").font(OF.section)
                    Text(dropLine).font(OF.meta).foregroundStyle(OC.textMuted)
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
        return (s.newCount == 1 ? "1 new file" : "\(s.newCount) new files") + (s.lastName.map { " · \($0)" } ?? "")
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
                Text(ws.name).font(OF.wsName)
                Label(ws.host, systemImage: "laptopcomputer").font(OF.meta).foregroundStyle(OC.textMuted)
                HStack(spacing: OS.s2) {
                    if waiting > 0 {
                        AttentionRail().frame(height: 22)
                        Label(waiting == 1 ? "1 question waiting" : "\(waiting) questions waiting",
                              systemImage: "questionmark.bubble").font(OF.meta).foregroundStyle(OC.you)
                    } else {
                        Label("Nothing needs you", systemImage: "checkmark.circle")
                            .font(OF.meta).foregroundStyle(OC.textMuted)
                    }
                }
                ConnectionChip(state: ws.connection)
            }
            .padding(.vertical, OS.s5)
            .padding(.trailing, OS.s5)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .orchCard()
        .clipShape(RoundedRectangle(cornerRadius: OR.card, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private var label: String {
        var parts = [ws.name]
        if ws.isHosted { parts.append(ws.hostedBy.map { "hosted by \($0)" } ?? "client hosted") }
        parts.append(waiting == 0 ? "nothing needs you" : "\(waiting) questions waiting")
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
                            QuestionRow(question: q, color: group.workspace.color, workspaceName: group.workspace.name)
                        }
                        .accessibilityIdentifier("question.\(q.id)")
                    }
                } header: {
                    HStack(spacing: OS.s2) {
                        WorkspaceRail(color: group.workspace.color).frame(height: 14).clipShape(Capsule())
                        Text(group.workspace.name).font(OF.section)
                        if group.workspace.isHosted { Image(systemName: "building.2").foregroundStyle(OC.hosted) }
                    }
                }
            }
            Section {
                Text("Last checked \(Fmt.relative(services.home.lastChecked))")
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
                Text(question.firstLine).lineLimit(2)
                Text("\(question.ticket) · \(workspaceName) · \(Fmt.relative(question.created))")
                    .font(OF.meta).foregroundStyle(OC.textMuted)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
