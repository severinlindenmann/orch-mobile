#if DEBUG
import SwiftUI
import OrchClient
import OrchFakeHost
import OrchUI

/// The hub home (V3 dev; design B2): the workspaces the hub lists, a switcher, and what needs the person. Deliberately minimal: the mockup
/// picks (A4) are still open, so only the essentials, in a layout that can be replaced. Every string from the hub goes through
/// `SafeTextView`; rows are display only.
struct HubHomeScreen: View {
    @State private var model: HubHomeModel
    @State private var password = ""
    @State private var totp = ""
    @State private var pairing: HubPairingModel?
    @State private var confirmLeave = false
    @Environment(\.dismiss) private var dismiss

    init(model: HubHomeModel = HubHomeModel()) { _model = State(initialValue: model) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: OS.s4) {
                    banner
                    if let snap = model.snapshot { content(snap) }
                }
                .padding(OS.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(OC.bg)
            .refreshable { await model.refresh() }
            .navigationTitle("Hub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() }.accessibilityIdentifier("hubhome.close") }
                ToolbarItem(placement: .topBarTrailing) { switcher }
                ToolbarItem(placement: .topBarTrailing) { leaveMenu }
            }
            .confirmationDialog("Leave this hub?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Leave the hub", role: .destructive) { Task { await model.leave() } }.accessibilityIdentifier("hubhome.leave.confirm")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This iPhone asks the hub to remove it, then deletes its keys and everything it saved from the hub. Your direct workspaces are not affected. To use the hub again you pair this iPhone again.")
            }
            .sheet(item: $pairing, onDismiss: { Task { await model.refresh() } }) { HubPairingScreen(model: $0) }
            .navigationDestination(for: HubNeedsYouRow.self) { HubItemScreen(model: model, row: $0) }
        }
        .task { await model.open() }
    }

    // MARK: leave and pair again (B6)

    @ViewBuilder private var leaveMenu: some View {
        switch model.state {
        case .notPaired, .revoked: EmptyView()
        default:
            Menu {
                Button("Leave this hub", role: .destructive) { confirmLeave = true }.accessibilityIdentifier("hubhome.leave")
            } label: { Image(systemName: "ellipsis.circle") }
                .disabled(model.leaving).accessibilityIdentifier("hubhome.more")
        }
    }

    private var pairAgainButton: some View {
        Button("Pair this iPhone again") {
            Task { if await model.pairAgain() { pairing = HubPairingModel.live() } }
        }
        .buttonStyle(.orchProminent).accessibilityIdentifier("hubhome.pairagain")
    }

    // MARK: switcher

    @ViewBuilder private var switcher: some View {
        if let snap = model.snapshot {
            Menu {
                Button { model.selected = nil } label: { Label("All workspaces", systemImage: model.selected == nil ? "checkmark" : "square.grid.2x2") }
                Divider()
                ForEach(snap.workspaces) { ws in
                    Button { model.selected = ws.id } label: {
                        Label { Text(Self.safe(Self.title(ws) + (ws.online ? "" : " (paused)"))) } icon: { Image(systemName: model.selected == ws.id ? "checkmark" : "folder") }
                    }
                }
            } label: {
                Label { Text(Self.safe(model.selectedWorkspace.map(Self.title) ?? "All workspaces")) } icon: { Image(systemName: "rectangle.stack") }.labelStyle(.titleAndIcon)
            }
            .accessibilityIdentifier("hubhome.switcher")
        }
    }

    /// Every string that came from the hub is shown through SafeText (look-alikes, odd spaces and invisible scalars get visible markers).
    static func safe(_ s: String) -> AttributedString { SafeText.attributed(s, style: .prose) }

    static func title(_ ws: HubWorkspace) -> String { ws.name ?? "Workspace " + ws.id.prefix(4) }

    // MARK: banner

    @ViewBuilder private var banner: some View {
        switch model.state {
        case .notPaired:
            VStack(alignment: .leading, spacing: OS.s3) {
                if let n = model.leaveNotice { note(n, icon: "checkmark.circle", color: OC.info, id: "hubhome.leavenotice") }
                note("This iPhone is not paired with a hub.", icon: "link.badge.plus", color: OC.textMuted, id: "hubhome.notpaired")
                pairAgainButton
            }
        case .live: EmptyView()
        case .offline(let snap):
            if let snap {
                note("Hub offline. Showing the last update from \(Self.time(snap.asOfMs)). You can read, but not answer or approve.", icon: "wifi.slash", color: OC.warn, id: "hubhome.offline")
            } else {
                note("Hub offline. There is nothing saved to show yet.", icon: "wifi.slash", color: OC.warn, id: "hubhome.offline")
            }
        case .signedOut:
            signInAgain(failure: nil)
        case .signInFailed(let f):
            signInAgain(failure: f)
        case .revoked:
            VStack(alignment: .leading, spacing: OS.s3) {
                note("The hub removed this iPhone, or its pairing ran out. What it saved from the hub is deleted. Pair it again to use the hub.",
                     icon: "xmark.shield", color: OC.danger, id: "hubhome.revoked")
                if let n = model.leaveNotice { note(n, icon: "exclamationmark.triangle", color: OC.warn, id: "hubhome.leavenotice") }
                pairAgainButton
            }
        }
    }

    private func signInAgain(failure: HubSignInFailure?) -> some View {
        VStack(alignment: .leading, spacing: OS.s3) {
            note("Your sign-in with the hub ended after 12 hours. This iPhone is still paired. Sign in again to see the hub.",
                 icon: "person.crop.circle.badge.exclamationmark", color: OC.warn, id: "hubhome.signedout")
            if let failure { Text(verbatim: Self.text(failure)).font(OF.body).foregroundStyle(OC.danger).accessibilityIdentifier("hubhome.signin.failure") }
            SecureField("Password", text: $password).textContentType(.password).padding(OS.s3).orchCard().accessibilityIdentifier("hubhome.password")
            TextField("Code from your authenticator app", text: $totp).keyboardType(.numberPad).padding(OS.s3).orchCard()
                .accessibilityIdentifier("hubhome.totp")
            Button("Sign in again") {
                let (p, t) = (password, totp)
                password = ""; totp = ""
                Task { await model.signInAgain(password: p, totp: t) }
            }
            .buttonStyle(.orchProminent).disabled(password.isEmpty || totp.count != 6).accessibilityIdentifier("hubhome.signin")
        }
    }

    static func text(_ f: HubSignInFailure) -> String {
        switch f {
        case .badCredentials: "Check your password and enter a new code. A code works once, so wait for the next one."
        case .rateLimited: "Too many tries. Wait a little and try again."
        case .network: "Could not reach the hub. Nothing changed."
        case .refused: "The hub refused. Nothing changed."
        case .verification: "The hub's answer did not check out, so this iPhone did not trust it. Nothing changed."
        }
    }

    private func note(_ text: String, icon: String, color: Color, id: String) -> some View {
        Label { Text(verbatim: text).font(OF.body) } icon: { Image(systemName: icon).foregroundStyle(color) }
            .frame(maxWidth: .infinity, alignment: .leading).padding(OS.s3).orchCard().accessibilityIdentifier(id)
    }

    static func role(_ r: String) -> String {
        switch r { case "owner": "You own it"; case "admin": "Can manage"; case "edit": "Can edit"; default: "Can read" }
    }

    static func time(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: Double(ms) / 1000)
        return Calendar.current.isDateInToday(d) ? d.formatted(date: .omitted, time: .shortened) : d.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: content

    @ViewBuilder private func content(_ snap: HubSnapshot) -> some View {
        let shown = model.selected.map { id in snap.workspaces.filter { $0.id == id } } ?? snap.workspaces
        if snap.workspaces.isEmpty {
            Text("The hub lists no workspaces for you.").font(OF.body).foregroundStyle(OC.textMuted).accessibilityIdentifier("hubhome.empty")
        }
        ForEach(shown) { ws in workspaceSection(ws, rows: snap.rows(in: ws.id), snap: snap) }
    }

    private func workspaceSection(_ ws: HubWorkspace, rows: [HubNeedsYouRow], snap: HubSnapshot) -> some View {
        VStack(alignment: .leading, spacing: OS.s3) {
            VStack(alignment: .leading, spacing: OS.s1) {
                HStack(spacing: OS.s2) {
                    Text(SafeText.attributed(Self.title(ws), style: .prose)).font(OF.wsName)
                    if !ws.online { StatusChip("Paused", systemImage: "pause.circle", color: OC.warn) }
                    if ws.mode == .selective { StatusChip("Shared items only", systemImage: "eye", color: OC.info) }
                }
                Text(Self.safe("Hub reads: " + ws.hubReads + " · " + Self.role(ws.role))).font(OF.meta).foregroundStyle(OC.textMuted)
            }
            if rows.isEmpty {
                Text(ws.online ? "Nothing needs you here." : "Paused: the workspace's computer is not connected, so nothing can be asked or signed.")
                    .font(OF.body).foregroundStyle(OC.textMuted)
            }
            ForEach(rows) { row in rowView(row, in: ws) }
        }
        .accessibilityIdentifier("hubhome.ws.\(ws.id.prefix(4))")
    }

    @ViewBuilder private func rowView(_ row: HubNeedsYouRow, in ws: HubWorkspace) -> some View {
        if row.summaryOnly {
            rowBody(row).overlay(alignment: .bottomLeading) { EmptyView() }
        } else {
            NavigationLink(value: row) { rowBody(row) }.buttonStyle(.plain).accessibilityIdentifier("hubhome.row.\(row.itemID)")
        }
    }

    private func rowBody(_ row: HubNeedsYouRow) -> some View {
        VStack(alignment: .leading, spacing: OS.s2) {
            HStack(spacing: OS.s2) {
                Text(verbatim: Self.kind(row)).font(OF.meta).foregroundStyle(OC.brand)
                if let k = row.key { Text(Self.safe(k)).font(OF.meta).foregroundStyle(OC.textMuted) }
            }
            SafeTextView(row.title ?? "(untitled)", style: .prose)
            if row.summaryOnly { Text("Handled where it lives").font(OF.meta).foregroundStyle(OC.textMuted) }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(OS.s3).orchCard()
    }

    static func kind(_ row: HubNeedsYouRow) -> String {
        switch row.kind {
        case "question": "Question"
        case "gate": "Approval"
        case "ticket": "Ticket"
        case "needs_you": "Needs you"
        default: "Item"
        }
    }
}

/// One item as the hub describes it. Fetched when opened, never from the cache; no sign button in B2.
struct HubItemScreen: View {
    let model: HubHomeModel
    let row: HubNeedsYouRow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OS.s4) {
                switch model.item {
                case .idle, .loading: HStack { ProgressView(); Text("Asking the hub…") }.accessibilityIdentifier("hubitem.loading")
                case .offline: Label("Hub offline. Items are only shown while the hub answers.", systemImage: "wifi.slash").foregroundStyle(OC.warn)
                        .accessibilityIdentifier("hubitem.offline")
                case .failed(let code): Text("The hub could not show this item. (\(code))").accessibilityIdentifier("hubitem.failed")
                case .ended: Text("The hub session ended. Go back.").accessibilityIdentifier("hubitem.ended")
                case .detail(let d): detail(d)
                }
            }
            .padding(OS.s4).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(OC.bg)
        .navigationTitle(HubHomeScreen.kind(row))
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(row) }
        .onDisappear { model.clearItem() }
    }

    private func detail(_ d: HubItemDetail) -> some View {
        VStack(alignment: .leading, spacing: OS.s4) {
            SafeTextView(d.row.title ?? "(untitled)", style: .prose).font(OF.wsName)
            if d.row.mode == .selective {
                StatusChip("Shared items only", systemImage: "eye", color: OC.info)
            }
            VStack(alignment: .leading, spacing: OS.s3) {
                ForEach(Array(d.lines.enumerated()), id: \.offset) { _, l in
                    VStack(alignment: .leading, spacing: OS.s1) {
                        Text(HubHomeScreen.safe(l.label)).font(OF.meta).foregroundStyle(OC.textMuted)
                        SafeTextView(l.value, style: .prose)
                    }
                }
            }
            .padding(OS.s4).frame(maxWidth: .infinity, alignment: .leading).orchCard()
            if let h = d.itemHash { Text(HubHomeScreen.safe("Shared content fingerprint: " + h)).font(OF.machine).foregroundStyle(OC.textMuted) }
            Text("Signing from this iPhone comes in a later version.").font(OF.meta).foregroundStyle(OC.textMuted)
        }
        .accessibilityIdentifier("hubitem.detail")
    }
}

extension HubNeedsYouRow: Hashable {
    public func hash(into h: inout Hasher) { h.combine(id) }
}

/// Settings entry: the pairing screen until paired, the home afterwards (decided each time the sheet opens).
struct HubEntryScreen: View {
    @State private var paired: Bool?
    @State private var pairing = HubPairingModel.live()

    var body: some View {
        Group {
            switch paired {
            case nil: ProgressView().task { paired = await HubRuntime.shared.home.restore() != .notPaired }
            case true?: HubHomeScreen()
            case false?: HubPairingScreen(model: pairing)
            }
        }
    }
}

/// `--hub-fake home|home-offline|home-signedout|home-revoked|home-selective`: the home against the in-process hub, paired without a screen.
struct HubHomeLaunchRoot: View {
    let script: String
    @State private var model = HubHomeModel()
    @State private var ready = false

    var body: some View {
        Group {
            if ready { HubHomeScreen(model: model) } else { ProgressView() }
        }
        .task {
            let rt = HubRuntime.shared
            await rt.pairFake()
            _ = await rt.home.refresh()
            if let hub = rt.fake {
                switch script {
                case "home-offline": hub.faults.down = true
                case "home-signedout": hub.faults.channelAnswer = "no_session"
                case "home-revoked": hub.faults.channelAnswer = "channel_revoked"
                default: break
                }
            }
            if script == "home-selective" { model.selected = FakeHub.wsShared }
            ready = true
        }
    }
}
#endif
