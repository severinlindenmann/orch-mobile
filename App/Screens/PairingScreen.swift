import SwiftUI
import OrchUI

/// Full-screen pairing flow (U5): one view per state. Codes never animate (V5).
struct PairingScreen: View {
    let model: any PairingFlowModel
    let onClose: () -> Void
    @State private var link = ""
    @State private var showScan = false
    @State private var showHostPanel = false
    @State private var showPrimaryPanel = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: OS.s4) {
                        if let step = stepNumber { stepIndicator(step) }
                        content
                    }
                        .padding(OS.s5)
                        .frame(maxWidth: .infinity)
                        .transaction { $0.animation = nil }
                }
                demoBar
            }
            .background(isAlarm ? OC.danger.opacity(0.12) : OC.bg)
            .navigationTitle("Pair a workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if case .ready = model.state {} else if isAlarm {} else {
                        Button("Cancel") { model.cancel(); onClose() }.accessibilityIdentifier("pair.cancel")
                    }
                }
            }
        }
        .onDisappear { model.screenClosed() }
        .sheet(isPresented: $showScan) { ScanPlaceholder() }
        .sheet(isPresented: $showHostPanel) { DemoHostPanel(model: model) }
        .sheet(isPresented: $showPrimaryPanel) { DemoPrimaryPanel(model: model) }
        .interactiveDismissDisabled()
    }

    /// 1 link, 2 compare, 3 add. Terminal states (expired, alarm, refused) show no progress.
    private var stepNumber: Int? {
        switch model.state {
        case .entry, .connecting: 1
        case .comparingHost, .waitingPrimary, .comparingPrimary: 2
        case .joining, .ready: 3
        case .expired, .alarm, .refused, .denied: nil
        }
    }

    private func stepIndicator(_ step: Int) -> some View {
        VStack(alignment: .leading, spacing: OS.s2) {
            HStack(spacing: 6) {
                ForEach(1...3, id: \.self) { i in
                    Capsule().fill(i <= step ? OC.brand : OC.surface3).frame(height: 4)
                }
            }
            Text(verbatim: "Step \(step) of 3").font(OF.meta).foregroundStyle(OC.textFaint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Step \(step) of 3"))
        .accessibilityIdentifier("pair.steps")
    }

    private var hostName: String { SafeText.label(model.hostLabel, limit: 24, allowDigits: false).nonEmpty ?? "your Mac" }

    private var isAlarm: Bool { if case .alarm = model.state { true } else { false } }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .entry: entry
        case .connecting:
            step(icon: "antenna.radiowaves.left.and.right", title: "Connecting…",
                 text: "Talking to the workspace host. Nothing to do yet.", id: "pair.connecting", spinner: true)
        case .comparingHost(let sas):
            VStack(spacing: OS.s4) {
                CodeDisplay(code: spaced(sas), title: "Compare with the code on \(hostName)", frame: .host, identifier: "pair.sas")
                Text(verbatim: "Approve only if both codes match. Reject on \(hostName) if they don't.")
                    .font(OF.body).foregroundStyle(OC.textMuted).multilineTextAlignment(.center)
                Label("Waiting for approval", systemImage: "hourglass").font(OF.meta).foregroundStyle(OC.textMuted)
                Button { model.cancel(); onClose() } label: { Text("They are different") }
                    .buttonStyle(.orchSoftDanger).accessibilityIdentifier("pair.different")
                    .accessibilityHint("Stops pairing on this iPhone. Nothing is added.")
            }
        case .waitingPrimary(let rawLabel, let deadline):
            let label = SafeText.label(rawLabel, limit: 24, allowDigits: false)
            VStack(spacing: OS.s4) {
                Image(systemName: "iphone.and.arrow.forward").font(.system(size: 56)).foregroundStyle(OC.brand)
                    .accessibilityHidden(true)
                Text(verbatim: "Open orch on \(label)").font(OF.display).multilineTextAlignment(.center)
                    .accessibilityIdentifier("pair.openPrimary")
                Text(verbatim: "\(label) will show a second code. The first code is gone.")
                    .font(OF.body).foregroundStyle(OC.textMuted).multilineTextAlignment(.center)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = max(0, Int(deadline.timeIntervalSince(ctx.date)))
                    Label { Text(verbatim: "Time left \(left / 60):\(String(format: "%02d", left % 60))") } icon: { Image(systemName: "timer") }
                        .font(OF.meta).accessibilityIdentifier("pair.countdown")
                }
            }
        case .comparingPrimary(let rawLabel, let code, let expires):
            let label = SafeText.label(rawLabel, limit: 24, allowDigits: false)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                if ctx.date < expires {
                    VStack(spacing: OS.s4) {
                        CodeDisplay(code: code, title: "Compare with \(label)", frame: .primary, identifier: "pair.certCode")
                        Text(verbatim: "Approve on \(label) only if the codes match.")
                            .font(OF.body).foregroundStyle(OC.textMuted).multilineTextAlignment(.center)
                        let left = max(0, Int(expires.timeIntervalSince(ctx.date)))
                        Label { Text(verbatim: "Code hidden in \(left / 60):\(String(format: "%02d", left % 60))") } icon: { Image(systemName: "timer") }
                            .font(OF.meta)
                        Button { model.cancel(); onClose() } label: { Text("They are different") }
                            .buttonStyle(.orchSoftDanger).accessibilityIdentifier("pair.different")
                            .accessibilityHint("Stops pairing on this iPhone. Nothing is added.")
                    }
                } else {
                    step(icon: "clock.badge.xmark", title: "The code timed out",
                         text: "Start again from your Mac.", id: "pair.certCodeHidden")
                }
            }
        case .joining:
            step(icon: "lock.shield", title: "Joining…", text: "Fetching the workspace key and checking it.",
                 id: "pair.joining", spinner: true)
        case .ready(let name):
            VStack(spacing: OS.s4) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 56)).foregroundStyle(OC.ok)
                    .accessibilityHidden(true)
                Text(verbatim: "Added \(name)").font(OF.display).multilineTextAlignment(.center)
                    .accessibilityIdentifier("pair.ready")
                Text("You can turn on notifications next.").font(OF.body).foregroundStyle(OC.textMuted)
                Button { onClose() } label: { Text("Done") }
                    .buttonStyle(.orchProminent).accessibilityIdentifier("pair.done")
            }
        case .expired:
            VStack(spacing: OS.s4) {
                step(icon: "clock.badge.xmark", title: "Nobody approved in time",
                     text: "Start again on your Mac to make a new link.", id: "pair.expired", tint: OC.warn)
                closeButton
            }
        case .alarm(let alarm): alarmView(alarm)
        case .denied(let owner):
            // attributed to the pinned owner key (the person of the link's pk_pin), never to a device name the host sent
            VStack(spacing: OS.s4) {
                step(icon: "hand.raised", title: "Denied by the owner",
                     text: "The owner of this workspace (owner key \(owner)) declined to sign this iPhone. Nothing was added.",
                     id: "pair.deniedByOwner", tint: OC.danger)
                closeButton
            }
        case .refused(let reason):
            VStack(spacing: OS.s4) {
                step(icon: "xmark.octagon", title: refusalTitle(reason), text: refusalText(reason), id: "pair.refused",
                     tint: refusalTint(reason))
                closeButton
            }
        }
    }

    private var closeButton: some View {
        Button { model.cancel(); onClose() } label: { Text("Close") }
            .buttonStyle(.orchSoft).accessibilityIdentifier("pair.close")
    }

    // MARK: Entry

    private var entry: some View {
        VStack(alignment: .leading, spacing: OS.s4) {
            OrbitMark(size: 40)
            Text("Add a workspace").font(OF.display)
            Text("On your Mac open orch, choose Remote, then Pair phone.").font(OF.body).foregroundStyle(OC.textMuted)
            Button { showScan = true } label: {
                Label("Scan QR code", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(.orchProminent).accessibilityIdentifier("pair.scan")
            VStack(alignment: .leading, spacing: OS.s2) {
                Text("Or paste the pairing link").font(OF.section)
                TextField("Pairing link", text: $link, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.URL)
                    .padding(OS.s3).background(OC.surface, in: RoundedRectangle(cornerRadius: OR.control, style: .continuous))
                    .accessibilityIdentifier("pair.paste")
                HStack {
                    // PasteButton reads the clipboard only when the user taps it.
                    PasteButton(payloadType: String.self) { strings in
                        if let s = strings.first { link = s }
                    }
                    Button("Use link") { model.submitLink(link) }
                        .buttonStyle(.bordered)
                        .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("pair.submit")
                }
            }
            if model.isDemo {
                Button { model.useDemoInvitation() } label: {
                    Label("Use Demo invitation", systemImage: "theatermasks").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(OC.demo).accessibilityIdentifier("pair.demoInvitation")
            }
        }
    }

    // MARK: Alarm (terminal; shows no codes)

    private func alarmView(_ alarm: PairingAlarm) -> some View {
        // No host-supplied digits or markup on alarm screens (S6).
        let (title, steps): (String, String) = switch alarm {
        case .echoWrongKey:
            ("Stop: this link is not for this iPhone", "Reject on your Mac (host). Do not approve any code. Make a new link.")
        case .r1Attack(let primary):
            ("Stop: someone else is trying to pair",
             "Reject on \(SafeText.label(primary, limit: 24, allowDigits: false).nonEmpty ?? "your primary device"). Do not confirm any code there. This host may be compromised.")
        case .substitution:
            ("Stop: the answer changed while pairing", "Abandon this pairing and reject any prompt still open on your Mac and your primary device.")
        }
        return VStack(spacing: OS.s4) {
            Image(systemName: "exclamationmark.octagon.fill").font(.system(size: 64)).foregroundStyle(OC.danger)
                .accessibilityHidden(true)
            Text(verbatim: title).font(OF.display).foregroundStyle(OC.danger).multilineTextAlignment(.center)
            Text(verbatim: steps).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text("No code is shown. Nothing was approved. Nothing was certified.").font(OF.body).foregroundStyle(OC.textMuted)
                .multilineTextAlignment(.center)
            Button(role: .destructive) { model.cancel(); onClose() } label: { Text("Close") }
                .buttonStyle(.orchDanger)
                .accessibilityIdentifier("pair.alarm.close")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pair.alarm")
    }

    // MARK: Helpers

    /// Rejections and refusals are never green: warning for "nothing happened in time", danger for a rejection.
    private func refusalTint(_ r: PairingRefusal) -> Color {
        switch r {
        case .rejectedOnHost, .rejectedOnPrimary, .linkUsed, .otherPerson, .couldNotVerify: OC.danger
        default: OC.warn
        }
    }

    private func step(icon: String, title: String, text: String, id: String, spinner: Bool = false, tint: Color? = nil) -> some View {
        VStack(spacing: OS.s4) {
            Image(systemName: icon).font(.system(size: 48)).foregroundStyle(tint ?? OC.brand).accessibilityHidden(true)
            Text(verbatim: title).font(OF.wsName).foregroundStyle(tint ?? OC.text).multilineTextAlignment(.center)
            Text(verbatim: text).font(OF.body).foregroundStyle(OC.textMuted).multilineTextAlignment(.center)
            if spinner { ProgressView() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    private func spaced(_ code: String) -> String {
        guard code.count == 6, !code.contains(" ") else { return code }
        return code.prefix(3) + " " + code.suffix(3)
    }

    private func refusalTitle(_ r: PairingRefusal) -> String {
        switch r {
        case .refused: "The pairing was refused"
        case .rejectedOnHost: "Not approved on your Mac"
        case .rejectedOnPrimary: "Not approved on your primary device"
        case .linkUsed: "This link was already used"
        case .otherPerson: "This workspace belongs to someone else"
        case .invalidLink: "This isn't an orch pairing link"
        case .relayNotConnected: "The relay isn't connected"
        case .timedOut: "No answer in time"
        case .alreadyMember: "This workspace is already on this iPhone"
        case .clockWrong: "This iPhone's clock is wrong"
        case .couldNotVerify: "The workspace could not be verified"
        case .keysInUse: "This iPhone's keys may be in use"
        case .keysUnavailable: "This iPhone's keys are not available"
        }
    }

    private func refusalText(_ r: PairingRefusal) -> String {
        switch r {
        case .refused: "Nothing was added. Start again on your Mac if you want to pair."
        case .rejectedOnHost: "Nothing was added. Start again on your Mac if you want to pair."
        case .rejectedOnPrimary: "Nothing was added. Your primary device did not sign this iPhone."
        case .linkUsed: "This link was used by someone else. Reject it on your Mac and make a new one."
        case .otherPerson: "This iPhone already belongs to another person. Nothing was sent."
        case .invalidLink: "The link is not valid, or it was cut off. Copy it again."
        case .relayNotConnected: "The relay isn't connected in this build. Try the Demo to see how pairing works."
        case .timedOut: "Nobody answered. Start again on your Mac."
        case .alreadyMember: "Nothing was changed. Remove the workspace from this iPhone first if you want to pair it again."
        case .clockWrong: "Set the date and time on this iPhone to automatic, then start again."
        case .couldNotVerify: "Nothing was added. Make a new link on your Mac and try again."
        case .keysInUse: "orch couldn't confirm that no other pairing is using these keys. Finish or cancel any other pairing, then try again."
        case .keysUnavailable: "Nothing was added. Unlock this iPhone and try again."
        }
    }

    // MARK: Demo bar

    @ViewBuilder
    private var demoBar: some View {
        if model.isDemo {
            VStack(alignment: .leading, spacing: OS.s2) {
                Divider()
                Text("Demo: the real pairing runs against a simulated Mac and primary on this iPhone.")
                    .font(OF.meta).foregroundStyle(OC.demo)
                    .padding(.horizontal, OS.s4)
                    .accessibilityIdentifier("demo.bar.label")
                let host = Button { showHostPanel = true } label: { Label("Demo host", systemImage: "laptopcomputer") }
                    .accessibilityIdentifier("demo.hostPanel.show")
                let primary = Button { showPrimaryPanel = true } label: { Label("Demo primary", systemImage: "key.horizontal") }
                    .accessibilityIdentifier("demo.primaryPanel.show")
                Group {
                    if typeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: OS.s2) { host; primary }
                    } else {
                        HStack { host; primary; Spacer(minLength: 0) }
                    }
                }
                .buttonStyle(.bordered).tint(OC.demo).font(OF.meta)
                .padding(.horizontal, OS.s4).padding(.bottom, OS.s2)
            }
            .background(OC.surface)
        }
    }
}

// MARK: Scan placeholder

struct ScanPlaceholder: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: OS.s4) {
                Image(systemName: "qrcode").font(.system(size: 56)).foregroundStyle(OC.textMuted)
                Text("Scanning isn't available in this build").font(OF.wsName).multilineTextAlignment(.center).accessibilityIdentifier("pair.scan.unavailable")
                Text("Paste the pairing link instead. Scanning comes in a later build.")
                    .font(OF.body).foregroundStyle(OC.textMuted).multilineTextAlignment(.center)
                Button { dismiss() } label: { Text("Paste link instead") }.buttonStyle(.orchProminent)
            }
            .padding(OS.s5)
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}

// MARK: Demo panels (U6): separately labelled, default Reject, Approve unlocks after "I compared the codes"

struct DemoHostPanel: View {
    let model: any PairingFlowModel
    @Environment(\.dismiss) private var dismiss
    @State private var compared = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("This panel plays the host Mac. It is not part of the real app.", systemImage: "theatermasks")
                        .foregroundStyle(OC.demo)
                }
                if case .comparingHost = model.state {
                    Section("Host screen shows") {
                        Text(verbatim: model.demoHostCode.prefix(3) + " " + model.demoHostCode.suffix(3))
                            .font(OF.code).kerning(6)
                            .accessibilityIdentifier("demo.hostPanel.code")
                    }
                    Section {
                        Toggle("I compared the codes", isOn: $compared).accessibilityIdentifier("demo.hostPanel.compared")
                        Button(role: .destructive) { model.hostReject(); dismiss() } label: { Text("Reject") }
                            .buttonStyle(.orchDanger)
                            .accessibilityIdentifier("demo.hostPanel.reject")
                        Button { model.hostApprove(); dismiss() } label: { Text("Approve") }
                            .buttonStyle(.orchProminent).disabled(!compared)
                            .accessibilityIdentifier("demo.hostPanel.approve")
                    }
                } else {
                    Section { Text("No pairing request is waiting on the host.").foregroundStyle(OC.textMuted) }
                }
                Section("Remote tab on the host") {
                    Button("New pairing link") { model.demoNewLink() }.accessibilityIdentifier("demo.hostPanel.newLink")
                    if !model.demoOfferLink.isEmpty {
                        Text(verbatim: model.demoOfferLink).font(OF.machine).textSelection(.enabled)
                            .accessibilityIdentifier("demo.hostPanel.link")
                        Button("Copy link") { UIPasteboard.general.string = model.demoOfferLink }
                            .accessibilityIdentifier("demo.hostPanel.copy")
                    }
                }
            }
            .navigationTitle("Demo host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() }.accessibilityIdentifier("demo.hostPanel.close") } }
        }
        .tint(OC.demo)
        .presentationDetents([.large])
    }
}

struct DemoPrimaryPanel: View {
    let model: any PairingFlowModel
    @Environment(\.dismiss) private var dismiss
    @State private var compared = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("This panel plays your primary device. It is not part of the real app.", systemImage: "theatermasks")
                        .foregroundStyle(OC.demo)
                }
                switch model.state {
                case .waitingPrimary:
                    Section("A request is waiting") {
                        Button { model.primaryOpenRequest(); if case .alarm = model.state { dismiss() } } label: {
                            Text("Open the request")
                        }
                        .buttonStyle(.orchProminent).accessibilityIdentifier("demo.primaryPanel.open")
                        Button("Let 10 minutes pass (primary offline)") { model.primaryTimeElapses(); dismiss() }
                            .accessibilityIdentifier("demo.primaryPanel.elapse")
                    }
                case .comparingPrimary:
                    // The primary's own screen: the code its fake derived, never the phone's.
                    Section("Primary shows") {
                        Text(verbatim: model.demoPrimaryCertCode).font(OF.code).kerning(6).accessibilityIdentifier("demo.primaryPanel.code")
                    }
                    Section {
                        Toggle("I compared the codes", isOn: $compared).accessibilityIdentifier("demo.primaryPanel.compared")
                        Button(role: .destructive) { model.primaryReject(); dismiss() } label: { Text("Reject") }
                            .buttonStyle(.orchDanger)
                            .accessibilityIdentifier("demo.primaryPanel.reject")
                        Button { model.primaryApprove(); dismiss() } label: { Text("Approve") }
                            .buttonStyle(.orchProminent).disabled(!compared || model.demoPrimaryCertCode.isEmpty)
                            .accessibilityIdentifier("demo.primaryPanel.approve")
                        Button("Let the code expire") { model.codeTimeElapses() }
                            .accessibilityIdentifier("demo.primaryPanel.expire")
                    }
                default:
                    Section {
                        Text(isExpired ? "The request expired. Nothing can be approved." : "No request is waiting on the primary.")
                            .foregroundStyle(OC.textMuted).accessibilityIdentifier("demo.primaryPanel.none")
                    }
                }
            }
            .navigationTitle("Demo primary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() }.accessibilityIdentifier("demo.primaryPanel.close") } }
        }
        .tint(OC.demo)
        .presentationDetents([.large])
    }

    private var isExpired: Bool { if case .expired = model.state { true } else { false } }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
