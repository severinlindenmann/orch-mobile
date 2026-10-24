import SwiftUI
import OrchClient
import OrchProtocol
import OrchUI

/// The sign prompt (V3 dev; design B3). Deliberately minimal and replaceable: the mockup (A4.2 B) is not final. Everything shown comes from
/// the checked `ctx` through `HubSignPrompt`; the screen never sees a digest, a key or a hub-written display string.
struct HubSignScreen: View {
    @Bindable var model: HubSignModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: OS.s5) {
                    switch model.state {
                    case .idle, .loading: progress("Asking your hub…")
                    case .review(let p): review(p)
                    case .signing(let p): signing(p)
                    case .signed(let r): signed(r)
                    case .failed(let f): failed(f)
                    }
                }
                .padding(OS.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(OC.bg)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    switch model.state {
                    case .signed, .failed, .signing: EmptyView()   // no Cancel once Face ID and the proof are under way (L2-B3-1)
                    default: Button("Cancel") { model.dismiss(); dismiss() }.accessibilityIdentifier("hubsign.cancel")
                    }
                }
            }
        }
        .interactiveDismissDisabled(model.busy)
    }

    private var title: String {
        switch model.state {
        case .signed: "Signed"
        case .failed(let f): f == .unknownOutcome ? "Not sure" : "Nothing was signed"
        case .review(let p), .signing(let p):
            switch p.facts.type {
            case "gate.approved": "Review approval"
            case "gate.changes_requested": "Review change request"
            case "verdict.given": "Review verdict"
            default: "Review your answer"
            }
        default: "Review your answer"
        }
    }

    // MARK: states

    private func review(_ p: HubSignPrompt) -> some View {
        VStack(alignment: .leading, spacing: OS.s5) {
            if let s = p.facts.sentence {
                SafeTextView(s).font(OF.wsName).accessibilityIdentifier("hubsign.sentence")
            } else {
                Label("This request has details this app does not recognise. Read every line under Signed details before you confirm.",
                      systemImage: "exclamationmark.triangle.fill").font(OF.body).foregroundStyle(OC.warn).accessibilityIdentifier("hubsign.unknown")
            }
            VStack(alignment: .leading, spacing: OS.s3) {
                if let g = p.facts.gate { row("Gate", g.prefix(1).uppercased() + g.dropFirst()) }
                if let h = p.facts.shortHash { row("Content reference", h, machine: true) }
                if let n = p.facts.gateGen { row("Round", String(n)) }
                ForEach(Array(p.facts.sources.enumerated()), id: \.offset) { _, s in row("Commit in \(s.repo)", s.sha, machine: true) }
                if let url = p.contentLink {
                    Link(destination: url) { Label("Open \(p.hubLabel)", systemImage: "arrow.up.right.square") }
                        .font(OF.body).accessibilityIdentifier("hubsign.link")
                }
            }
            .padding(OS.s4).orchCard()
            if p.facts.selective {
                Label("Selective: the hub sees only what was shared", systemImage: "eye").font(OF.meta).foregroundStyle(OC.info)
                    .accessibilityIdentifier("hubsign.selective")
            }
            if p.facts.shortHash != nil {
                Text("Check that this matches the content reference in Mission Control. Your hub cannot vouch for itself.").font(OF.meta).foregroundStyle(OC.textMuted)
            }
            DisclosureGroup("Signed details") {
                VStack(alignment: .leading, spacing: OS.s2) {
                    row("Signature reference", p.reference, machine: true)
                    ForEach(Array(p.facts.fields.enumerated()), id: \.offset) { _, f in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: f.name).font(OF.meta).foregroundStyle(OC.textMuted)
                            SafeTextView(f.value).font(OF.machine)
                        }
                    }
                }.padding(.top, OS.s2)
            }.accessibilityIdentifier("hubsign.details")
            Text("Check the answer above. When you confirm, your iPhone checks it is you with Face ID, and \(p.hubLabel) signs and sends it for you.")
                .font(OF.meta).foregroundStyle(OC.textMuted)
            Button { model.confirm() } label: { Label("Confirm with Face ID", systemImage: "faceid").frame(maxWidth: .infinity) }
                .buttonStyle(.orchProminent).accessibilityIdentifier("hubsign.confirm")
        }
    }

    private func signing(_ p: HubSignPrompt) -> some View {
        VStack(alignment: .leading, spacing: OS.s4) {
            if let s = p.facts.sentence { SafeTextView(s).font(OF.wsName) }
            progress("Waiting for Face ID…")
        }
    }

    private func signed(_ r: HubSignReceipt) -> some View {
        VStack(alignment: .leading, spacing: OS.s4) {
            Label("Signed by hub", systemImage: "checkmark.seal.fill").font(OF.wsName).foregroundStyle(OC.ok).accessibilityIdentifier("hubsign.signed")
            Text("\(r.hubLabel) signed this for you. The item list shows the result.").font(OF.body).foregroundStyle(OC.textMuted)
            Button("Done") { dismiss() }.buttonStyle(.orchProminent).accessibilityIdentifier("hubsign.done")
        }
    }

    private func failed(_ f: HubSignFailure) -> some View {
        VStack(alignment: .leading, spacing: OS.s4) {
            Label(f == .unknownOutcome ? "We can't tell if this was signed" : "Nothing was signed", systemImage: "exclamationmark.triangle.fill")
                .font(OF.wsName).foregroundStyle(f == .unknownOutcome ? OC.warn : OC.danger)
            Text(verbatim: Self.text(f)).font(OF.body).accessibilityIdentifier("hubsign.failure")
            Button("Close") { dismiss() }.buttonStyle(.orchProminent).accessibilityIdentifier("hubsign.close")
        }
    }

    // MARK: pieces

    private func progress(_ text: String) -> some View {
        HStack(spacing: OS.s3) { ProgressView(); Text(text).font(OF.body) }
            .frame(maxWidth: .infinity, alignment: .leading).padding(OS.s4).orchCard().accessibilityIdentifier("hubsign.progress")
    }

    private func row(_ label: String, _ value: String, machine: Bool = false) -> some View {
        LabeledContent(label) { Text(verbatim: value).font(machine ? OF.machine : OF.body).textSelection(.enabled) }
    }

    /// Fixed local texts: nothing the hub wrote is shown.
    static func text(_ f: HubSignFailure) -> String {
        switch f {
        case .offline: "Your hub does not answer. Nothing was sent. Try again when you are back online."
        case .notPaired: "This iPhone is not paired with a hub."
        case .signInAgain: "Sign in to your hub again, then ask for this again. Your iPhone is still paired."
        case .notSignable: "This iPhone only signs answers, approvals, change requests and verdicts. Do this one in your hub's browser."
        case .contentNotReachable: "There is nowhere to read what you would approve, so this iPhone does not offer it. Open your hub in a browser."
        case .changed: "What your hub prepared is not what you asked for, or is not meant for this iPhone. Nothing was signed. Ask again."
        case .expired: "This request ran out. Ask for it again."
        case .biometry(let b):
            switch b {
            case .unavailable: "Face ID is not available. Signing needs Face ID on this iPhone."
            case .notEnrolled: "Set up Face ID in Settings to sign with this iPhone."
            case .lockedOut: "Face ID is locked. Unlock your iPhone with its passcode, then try again."
            case .cancelled, .failed: "Face ID did not confirm it was you."
            case .changed: "Face ID changed since this iPhone was paired. Sign in to your hub again."
            }
        case .hub(let code): code == "channel_revoked" ? "Your hub no longer accepts this iPhone." : "Your hub refused this request."
        case .unknownOutcome: "The answer from your hub was lost. Do not sign again yet: check the item list to see whether it went through."
        case .custody: "This iPhone could not read its key. Is it unlocked?"
        case .notLive: "This request is no longer open. Ask for it again."
        }
    }
}
