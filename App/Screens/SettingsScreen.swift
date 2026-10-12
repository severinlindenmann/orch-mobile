import SwiftUI
import OrchUI

struct SettingsScreen: View {
    let services: any AppServices
    @Binding var path: [Route]
    @State private var confirmReset = false

    private var model: any SettingsModel { services.settings }

    var body: some View {
        Form {
            Section("This iPhone") {
                TextField("Device label", text: Binding(get: { model.deviceLabel }, set: { model.deviceLabel = $0 }))
                    .accessibilityIdentifier("settings.deviceLabel")
                LabeledContent("Key custody", value: model.custody)
                LabeledContent("Notifications", value: notificationText)
                if model.notificationStatus == .denied {
                    Button("Open iOS Settings") { model.openNotificationSettings() }
                        .accessibilityIdentifier("settings.notifications.openSettings")
                }
                if !model.pushDiagnostics.isEmpty {
                    Text(verbatim: model.pushDiagnostics).font(OF.meta).foregroundStyle(OC.textMuted)
                        .accessibilityIdentifier("settings.push.diagnostics")
                }
            }
            if !model.pendingServerCleanups.isEmpty {
                Section {
                    ForEach(model.pendingServerCleanups) { item in
                        Label("A removed workspace: server cleanup pending", systemImage: "arrow.triangle.2.circlepath")
                            .accessibilityIdentifier("settings.serverCleanup.\(item.id)")
                    }
                    Button("Retry now") { Task { await model.retryServerCleanup() } }
                        .accessibilityIdentifier("settings.serverCleanup.retry")
                } header: { Text("Finish on your Mac") } footer: {
                    Text("These workspaces are already removed from this iPhone. Stopping their notifications on the server is retried when you are online.")
                }
            }
            Section("Workspaces") {
                if model.workspaces.isEmpty { Text("No workspaces.").foregroundStyle(OC.textMuted) }
                ForEach(model.workspaces) { ws in
                    NavigationLink(value: Route.workspaceSettings(ws.id, confirmLeave: false)) {
                        HStack {
                            WorkspaceRail(color: ws.color).frame(height: 24).clipShape(Capsule())
                            Text(verbatim: ws.displayName)
                        }
                    }
                    .accessibilityIdentifier("settings.workspace.\(ws.id)")
                }
            }
            if model.isDemo { demoSection }
            Section { SimulationNotice() }
            Section("If you lose a device") {
                VStack(alignment: .leading, spacing: OS.s2) {
                    Label("Revocation is different from leaving", systemImage: "exclamationmark.shield").font(OF.section)
                    Text("To cut off a lost iPhone, revoke it in orch on your primary device. Once that is verified here, this iPhone's identity is dead, every workspace on it is wiped, and it needs new keys to pair again. Leaving a workspace only removes that workspace from this iPhone.")
                        .font(OF.body).foregroundStyle(OC.textMuted)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.revocation")
            }
            Section {
                Button("Reset this iPhone", role: .destructive) { confirmReset = true }
                    .accessibilityIdentifier("settings.reset")
            } footer: {
                Text("Wipes every workspace and the device keys from this iPhone. It does not remove it from your Mac.")
            }
        }
        .navigationTitle("Settings")
        .task { await model.refreshNotificationStatus() }
        .alert("Reset this iPhone?", isPresented: $confirmReset) {
            Button("Reset this iPhone", role: .destructive) { model.resetThisiPhone(); path = [] }
                .accessibilityIdentifier("settings.reset.confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This wipes all workspaces, files and the device keys from this iPhone. You will need to pair again.")
        }
    }

    private var notificationText: String {
        switch model.notificationStatus {
        case .notAsked: "Not asked yet"
        case .allowed: "Allowed"
        case .denied: "Off in iOS Settings"
        }
    }

    private var demoSection: some View {
        Section {
            Picker("Next pairing", selection: Binding(get: { model.pairingScenario }, set: { model.pairingScenario = $0 })) {
                ForEach(PairingScenario.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("demo.nextPairing")
            Picker("Next answer ends as", selection: Binding(get: { model.signOutcome }, set: { model.signOutcome = $0 })) {
                ForEach(SignOutcome.liveCases, id: \.self) { Text($0.title).tag($0) }
            }
            Button("Send a demo question notification") { Task { await model.demoSendNotification() } }
                .accessibilityIdentifier("demo.sendNotification")
            Text("Answer it in orch — the notification then changes to “Answered on …”.").font(OF.meta).foregroundStyle(OC.textMuted)
                .accessibilityIdentifier("demo.sendNotification.hint")
            if let result = model.demoPushResult {
                Text(verbatim: result).font(OF.meta).foregroundStyle(OC.textMuted)
                    .accessibilityIdentifier("demo.sendNotification.result")
            }
            Button("Reset Demo data") { model.resetDemoData() }.accessibilityIdentifier("demo.reset")
            Button("Leave Demo", role: .destructive) { model.exitDemo(); path = [] }
                .accessibilityIdentifier("demo.leave")
        } header: {
            Label("Demo controls", systemImage: "theatermasks").foregroundStyle(OC.demo)
        } footer: {
            Text("Leaving Demo wipes the Demo workspaces from this iPhone.")
        }
    }
}

struct WorkspaceSettingsScreen: View {
    let services: any AppServices
    let workspaceID: String
    @Binding var path: [Route]
    @State private var confirm: Bool
    @State private var report: LeaveReport?
    @State private var simulateOffline = false

    init(services: any AppServices, workspaceID: String, confirmLeave: Bool, path: Binding<[Route]>) {
        self.services = services
        self.workspaceID = workspaceID
        _path = path
        _confirm = State(initialValue: confirmLeave)
    }

    var body: some View {
        let model = services.settings
        let ws = model.workspaces.first { $0.id == workspaceID }
        Form {
            if let ws {
                Section {
                    WorkspaceHeader(name: ws.name, color: ws.color, hostedBy: ws.hostedBy, clientHosted: ws.clientHosted)
                    LabeledContent("Host", value: ws.displayHost)
                    LabeledContent("Allowed here", value: ws.scopes.map(\.rawValue).sorted().joined(separator: ", "))
                }
                Section {
                    Toggle("Notifications", isOn: Binding(get: { ws.notificationsOn },
                                                          set: { model.setNotifications($0, workspaceID: ws.id) }))
                        .accessibilityIdentifier("settings.notifications")
                }
                if model.isDemo {
                    Section("Demo") {
                        Toggle("Pretend this iPhone is offline", isOn: $simulateOffline)
                            .accessibilityIdentifier("demo.offline")
                        Button("Send a Demo notification") { model.demoSendPush(workspaceID: ws.id) }
                            .accessibilityIdentifier("demo.push")
                        if let result = model.demoPushResult {
                            Text(verbatim: result).font(OF.meta).foregroundStyle(OC.textMuted).accessibilityIdentifier("demo.push.result")
                        }
                    }
                }
                if let report, report.incomplete {
                    Section {
                        Label("Removal incomplete. This workspace is still on this iPhone. Try again.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(OC.warn).accessibilityIdentifier("settings.leave.incomplete")
                        if let failure = report.failure {
                            Text(verbatim: "Details: \(failure)").font(OF.meta).foregroundStyle(OC.textMuted)
                                .accessibilityIdentifier("settings.leave.failure")
                        }
                    }
                }
                Section {
                    Button("Remove from this iPhone", role: .destructive) { confirm = true }
                        .accessibilityIdentifier("settings.leave")
                } footer: {
                    Text("Removing a workspace only affects this iPhone. To cut off a lost device, revoke it on your primary.")
                }
            } else if let report, !report.incomplete {
                Section {
                    Label("Removed from this iPhone", systemImage: "checkmark.circle.fill").foregroundStyle(OC.ok)
                        .accessibilityIdentifier("settings.leave.done")
                    Text(verbatim: serverText(report)).font(OF.body)
                        .accessibilityIdentifier("settings.leave.server")
                    Button("Done") { path = [] }.accessibilityIdentifier("settings.leave.close")
                }
            } else {
                Text("This workspace is no longer on this iPhone.")
            }
        }
        .navigationTitle(Text(verbatim: ws?.displayName ?? "Workspace"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(Text(verbatim: "Remove \(ws?.displayName ?? "workspace") from this iPhone?"), isPresented: $confirm) {
            Button("Remove from this iPhone", role: .destructive) {
                Task { report = await model.leave(workspaceID: workspaceID, simulateOffline: simulateOffline) }
            }
            .accessibilityIdentifier("settings.leave.confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its questions, files and keys are deleted from this iPhone now, even if you are offline. Stopping notifications on the server is tried afterwards and may stay pending. Your other devices keep access and nothing on your Mac changes.")
        }
    }

    private func serverText(_ r: LeaveReport) -> String {
        switch r.server {
        case .done: "Notifications for \(SafeText.inline(r.workspaceName, limit: 40)) were stopped on the server."
        case .pendingOffline: "You are offline, so stopping notifications on the server is still pending. It will be tried again when you are back online. Finish on your Mac if it stays pending."
        case .finishOnMac: "This iPhone can't remove itself from the server for \(SafeText.inline(r.workspaceName, limit: 40)). Finish on your Mac."
        }
    }
}
