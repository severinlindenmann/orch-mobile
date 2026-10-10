import SwiftUI
import OrchUI

/// M1 display fixtures only: no transport, persistence, or security operations.
private struct PreviewWorkspace: Identifiable {
    let id: String
    let name: String
    let host: String
    let hue: Int
    let hostedBy: String?
    let question: String
    let age: String

    static let samples = [
        Self(id: "laptop", name: "Laptop", host: "Your MacBook", hue: 0,
             hostedBy: nil, question: "Ready to review the changes?", age: "20 minutes ago"),
        Self(id: "client-vm", name: "Client VM", host: "Development VM", hue: 1,
             hostedBy: "Acme", question: "Which approach should we try?", age: "5 minutes ago")
    ]
}

struct HomeScreen: View {
    @State private var demo: Bool
    @State private var notice: String?

    init(options: LaunchOptions) {
        _demo = State(initialValue: options.demo)
    }

    var body: some View {
        NavigationStack {
            Group {
                if demo { home } else { welcome }
            }
            .background(OC.bg)
            .navigationTitle("orch")
            .toolbar {
                if demo {
                    ToolbarItem(placement: .topBarLeading) {
                        Label("Demo", systemImage: "theatermasks").foregroundStyle(OC.demo)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Add workspace", systemImage: "plus") {
                        notice = "The relay isn't connected in this build."
                    }
                    Button("Settings", systemImage: "gearshape") {
                        notice = "Settings comes in a later milestone."
                    }
                }
            }
            .alert("orch", isPresented: Binding(
                get: { notice != nil }, set: { if !$0 { notice = nil } }
            )) {
                Button("OK", role: .cancel) { notice = nil }
            } message: { Text(notice ?? "") }
        }
        .tint(OC.brand)
        .symbolRenderingMode(.hierarchical)
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OS.s3) {
                Text("Static preview · no workspace connected")
                    .font(OF.meta).foregroundStyle(OC.textMuted)
                NavigationLink {
                    needsYou
                } label: {
                    HStack(spacing: OS.s3) {
                        Image(systemName: "questionmark.bubble").foregroundStyle(OC.you)
                        VStack(alignment: .leading, spacing: OS.s1) {
                            Text("Needs you").font(OF.section).foregroundStyle(OC.you)
                            Text("Laptop · Ready to review the changes?").font(OF.body)
                            Text("Last checked in this preview").font(OF.meta).foregroundStyle(OC.textMuted)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                    }
                    .padding(OS.s5)
                    .background(OC.surface, in: RoundedRectangle(cornerRadius: OR.card))
                    .overlay(alignment: .leading) { AttentionRail().padding(.leading, OS.s2).padding(.vertical, OS.s3) }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.needsYou")

                ForEach(PreviewWorkspace.samples) { workspace in
                    Button {
                        notice = "\(workspace.name) is a static preview. Workspace details come later."
                    } label: {
                        workspaceCard(workspace)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.workspace.\(workspace.id)")
                }

                Button {
                    notice = "Drop comes in a later milestone."
                } label: {
                    HStack(spacing: OS.s3) {
                        Image(systemName: "tray.and.arrow.down")
                        VStack(alignment: .leading) {
                            Text("Drop").font(OF.section)
                            Text("Files and notes from your workspaces").font(OF.meta)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(OS.s5)
                    .background(OC.surface, in: RoundedRectangle(cornerRadius: OR.card))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.drop")
            }
            .padding(OS.s4)
        }
        .foregroundStyle(OC.text)
    }

    private func workspaceCard(_ workspace: PreviewWorkspace) -> some View {
        HStack(spacing: OS.s3) {
            WorkspaceRail(color: OC.wsHues[workspace.hue])
            VStack(alignment: .leading, spacing: OS.s2) {
                if let hostedBy = workspace.hostedBy {
                    Label("Hosted by \(hostedBy)", systemImage: "building.2")
                        .font(OF.meta).foregroundStyle(OC.hosted)
                        .padding(OS.s2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(OC.soft(OC.hosted), in: RoundedRectangle(cornerRadius: OR.control))
                }
                Text(workspace.name).font(OF.wsName)
                Label(workspace.host, systemImage: "laptopcomputer")
                    .font(OF.meta).foregroundStyle(OC.textMuted)
                HStack {
                    AttentionRail().frame(height: 24)
                    Label("Question waiting · preview", systemImage: "questionmark.bubble")
                        .font(OF.meta).foregroundStyle(OC.you)
                }
            }
            .padding(.vertical, OS.s5)
            .padding(.trailing, OS.s5)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(OC.surface, in: RoundedRectangle(cornerRadius: OR.card))
        .clipShape(RoundedRectangle(cornerRadius: OR.card))
        .accessibilityElement(children: .combine)
    }

    private var needsYou: some View {
        List {
            // Fixtures are oldest first; each workspace retains its identity rail.
            ForEach(PreviewWorkspace.samples) { workspace in
                Section(workspace.name) {
                    HStack(spacing: OS.s3) {
                        WorkspaceRail(color: OC.wsHues[workspace.hue])
                        VStack(alignment: .leading, spacing: OS.s1) {
                            Text(workspace.question)
                            Text("\(workspace.name) · \(workspace.age)")
                                .font(OF.meta).foregroundStyle(OC.textMuted)
                        }
                    }
                }
            }
            Text("Static preview · last checked in this preview").font(OF.meta)
        }
        .navigationTitle("Needs you")
        .safeAreaInset(edge: .top) {
            Label("Demo", systemImage: "theatermasks").foregroundStyle(OC.demo)
        }
    }

    private var welcome: some View {
        VStack(spacing: OS.s5) {
            Spacer()
            Image(systemName: "square.stack.3d.up").font(OF.display).foregroundStyle(OC.brand)
            Text("Welcome to orch").font(OF.display)
            Text("Your workspaces, on your iPhone.").font(OF.body)
            Button("Try Demo") { demo = true }
                .buttonStyle(.borderedProminent)
            Button("Pair a workspace") { notice = "The relay isn't connected in this build." }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(OS.s5)
    }
}
