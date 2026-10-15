import Foundation
import Observation
import OrchClient

/// Why an invitation was turned away without any network access.
enum InvitationRefusal: Equatable, Sendable {
    /// Not an orch pairing link (or cut off).
    case invalidLink
    /// Not an `https` relay origin Live accepts (a loopback `http` origin, or a Demo link).
    case unsupportedOrigin(String)
    /// This iPhone is already paired through another relay origin: one origin per Live install, never retargeted.
    case differentOrigin(existing: String, offered: String)
    /// A realm transition or an unfinished removal is in progress; nothing can be started now.
    case busy
}

/// What the Live entry flow is showing. Presented above the realm's view graph (it survives the Welcome -> Live graph changes).
enum IntakeScreen: Equatable {
    /// Scan or paste.
    case entry
    /// Review of a parsed invitation: the reviewed origin, read-only, and "Connect". Nothing is sent before Connect.
    case review(PairingLink)
    /// Demo is active: the link is held in memory and the person is offered the destructive switch. Never switched automatically.
    case switchOffer(PairingLink)
    case refused(InvitationRefusal)
    /// Demo is being wiped for the switch; the held link (if any) is reviewed when that is done.
    case leavingDemo
    /// The Live pairing itself (the existing pairing screen over a Live model).
    case pairing
}

/// The one place a pairing link enters the app: the in-app scanner, the paste field and `orch://` opens all end in `handle(text:)`, and
/// every one of them lands on a review screen. An open NEVER connects by itself and never leaves Demo by itself.
@MainActor @Observable
final class LiveIntake {
    private(set) var screen: IntakeScreen?
    /// The pairing flow on screen (set with `.pairing`).
    private(set) var pairingModel: (any PairingFlowModel)?
    /// A link opened while Demo is active, kept in memory only until the person decides.
    private(set) var held: PairingLink?
    private(set) var notice: String?
    private(set) var leavingDemo = false
    /// The text of the last failed paste (shown under the field).
    private(set) var entryError: String?

    @ObservationIgnored private let realm: RealmController
    @ObservationIgnored private var leaveTask: Task<Void, Never>?
    /// A link that arrived before the realm finished booting (a cold launch from `orch://`): classified once the realm is known.
    @ObservationIgnored private var early: String?

    init(realm: RealmController) { self.realm = realm }

    var isPresented: Bool { screen != nil }

    // MARK: Opening

    /// "Pair your Mac" / "Add workspace": the scan-or-paste entry. Ignored while a pairing is on screen.
    func openEntry() {
        if case .pairing = screen { return }
        entryError = nil
        screen = classifyEntry()
    }

    private func classifyEntry() -> IntakeScreen {
        switch realm.state {
        case .welcome, .live: .entry
        case .demo: .entry          // a pasted link is classified when it arrives (switch offer)
        case .starting, .leaving, .recoveryRequired: .refused(.busy)
        }
    }

    /// `onOpenURL` (cold launch included). Only the `orch` scheme is ours; anything else is ignored.
    func handle(url: URL) {
        guard url.scheme?.lowercased() == "orch" else { return }
        handle(text: url.absoluteString)
    }

    func realmBooted() {
        guard let text = early else { return }
        early = nil
        handle(text: text)
    }

    /// A scanned or pasted string, or an opened `orch://` URL. Parses locally (no network), then lands on a screen.
    func handle(text raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard realm.booted else { early = text; return }
        if case .pairing = screen, let model = pairingModel, !Self.isFinished(model.state) {
            notice = "Finish or cancel this pairing before opening another invitation."
            return
        }
        notice = nil
        guard let link = try? PairingLink.parse(text) else {
            // On the entry screen the error is inline; an open from outside gets a refusal screen.
            if case .entry = screen { entryError = "This isn't an orch pairing link, or it was cut off. Copy it again." }
            else { screen = .refused(.invalidLink) }
            return
        }
        entryError = nil
        screen = classify(link)
    }

    /// Where an invitation goes, decided before any network access.
    func classify(_ link: PairingLink) -> IntakeScreen {
        guard LiveServices.isLiveOrigin(link.reviewedOrigin) else { return .refused(.unsupportedOrigin(link.reviewedOrigin)) }
        switch realm.state {
        case .starting, .leaving, .recoveryRequired:
            return .refused(.busy)
        case .demo:
            held = link
            return .switchOffer(link)
        case .welcome, .live:
            if let existing = realm.services.liveOrigin, existing != link.reviewedOrigin {
                return .refused(.differentOrigin(existing: existing, offered: link.reviewedOrigin))
            }
            return .review(link)
        }
    }

    // MARK: Actions

    /// "Connect" on the review screen: the first moment anything is written or sent.
    func connect(_ link: PairingLink) {
        guard case .review = screen else { return }
        let model = realm.services.makeLivePairing(link: link)
        pairingModel = model
        screen = .pairing
    }

    /// "Leave Demo and pair your Mac", after the destructive confirmation: wipes Demo, then returns to the review of the held link (or to
    /// the entry when none was held).
    func leaveDemoAndPair() {
        guard realm.state == .demo, !leavingDemo else { return }
        leavingDemo = true
        screen = .leavingDemo
        realm.realmLeave(thenDemo: false)
        leaveTask = Task { [weak self] in
            await self?.realm.waitForTransition()
            guard let self else { return }
            self.leavingDemo = false
            if self.realm.state == .welcome {
                if let link = self.held { self.screen = self.classify(link) } else { self.screen = .entry }
            } else {
                self.screen = .refused(.busy)
            }
        }
    }

    func dismiss() {
        pairingModel?.screenClosed()
        pairingModel = nil
        held = nil
        screen = nil
        entryError = nil
    }

    func clearNotice() { notice = nil }

    private static func isFinished(_ state: PairingState) -> Bool {
        switch state {
        case .ready, .alarm, .refused, .expired, .denied, .entry: true
        default: false
        }
    }
}

extension InvitationRefusal {
    var title: String {
        switch self {
        case .invalidLink: "This isn't an orch pairing link"
        case .unsupportedOrigin: "This invitation can't be used"
        case .differentOrigin: "This iPhone uses a different relay"
        case .busy: "Not right now"
        }
    }

    var detail: String {
        switch self {
        case .invalidLink: "The link is not valid, or it was cut off. Copy it again from your Mac."
        case .unsupportedOrigin: "Only secure (https) relays can be used. Nothing was sent and nothing was changed."
        case .differentOrigin: "This iPhone is already set up with another relay and another owner. Leave Live in Settings first if you want to use this invitation. Nothing was sent."
        case .busy: "orch is finishing something else. Finish or retry that first, then open the invitation again."
        }
    }
}
