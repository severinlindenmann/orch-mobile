import Foundation

enum WorkspaceSegment: String, CaseIterable, Hashable, Sendable {
    case questions, tickets, files, terminal
    var title: String {
        switch self {
        case .questions: "Questions"
        case .tickets: "Tickets"
        case .files: "Files"
        case .terminal: "Terminal"
        }
    }
}

enum Route: Hashable {
    case needsYou
    case workspace(String, WorkspaceSegment)
    case question(workspace: String, id: String, autoSign: Bool)
    case ticket(workspace: String, key: String)
    case drop
    case dropItem(String)
    case settings
    case workspaceSettings(String, confirmLeave: Bool)
    /// DEBUG-only fixture that presents a real UIActivityViewController (decision T2).
    case shareFixture
}

/// Result of parsing `--initial-route`.
struct InitialRoute: Equatable {
    var path: [Route] = []
    var pairing: PairingState?
    var presentPairing = false
    var composeDrop = false
    var forceWelcome = false
}

@MainActor
enum InitialRouteParser {
    static func parse(_ raw: String?, services: any AppServices) -> InitialRoute {
        var result = InitialRoute()
        guard let raw, !raw.isEmpty else { return result }
        let parts = raw.split(separator: "/").map(String.init)
        guard let head = parts.first else { return result }
        let arg = parts.count > 1 ? parts[1] : nil
        switch head {
        case "welcome": result.forceWelcome = true
        case "empty": (services as? PreviewWorld)?.removeAllWorkspaces()   // preview only; a live launch without --demo-seed is already empty
        case "needs-you": result.path = [.needsYou]
        case "workspace":
            if let raw = arg, let id = services.resolveWorkspace(raw) {
                let seg = parts.count > 2 ? WorkspaceSegment(rawValue: parts[2]) ?? .questions : .questions
                result.path = [.workspace(id, seg)]
            }
        case "ticket":
            if parts.count > 2, let ws = services.resolveWorkspace(parts[1]) {
                result.path = [.workspace(ws, .tickets), .ticket(workspace: ws, key: parts[2])]
            }
        case "question", "sign":
            if let raw = arg, let (ws, qid) = services.resolveQuestion(raw) {
                let sign = head == "sign"
                if parts.count > 2, let outcome = SignOutcome(rawValue: parts[2]) {
                    services.settings.signOutcome = outcome
                }
                result.path = [.workspace(ws, .questions), .question(workspace: ws, id: qid, autoSign: sign)]
            }
        case "pair":
            result.presentPairing = true
            if let s = arg { result.pairing = pairingState(s, services: services) }
        case "drop":
            result.path = [.drop]
            if arg == "compose" { result.composeDrop = true }
            if arg == "item", parts.count > 2 { result.path.append(.dropItem(parts[2])) }
        case "share-fixture": result.path = [.shareFixture]
        case "settings":
            result.path = [.settings]
            if arg == "workspace" || arg == "leave", parts.count > 2, let ws = services.resolveWorkspace(parts[2]) {
                result.path.append(.workspaceSettings(ws, confirmLeave: arg == "leave"))
            }
        default: break
        }
        return result
    }

    static func pairingState(_ name: String, services: any AppServices) -> PairingState? {
        // On the live Demo stack a route cannot jump to a state: it only picks what the fakes do next (the scenario), and pairing starts at entry.
        if services is LiveServices {
            let scenarios: [String: PairingScenario] = ["r1": .r1Attack, "wrongKey": .echoWrongKey, "linkUsed": .linkUsed,
                                                       "primaryOffline": .primaryOffline, "existingCert": .existingCert, "refused": .rejectOnHost]
            if let scenario = scenarios[name] { services.settings.pairingScenario = scenario }
            return nil
        }
        let primary = "Demo Mac"
        switch name {
        case "entry": return .entry
        case "connecting": return .connecting
        case "sas": return .comparingHost(sas: "K7QMX2")
        case "certPending": return .waitingPrimary(primaryLabel: primary, deadline: Date().addingTimeInterval(600))
        case "certCode": return .comparingPrimary(primaryLabel: primary, certCode: "493 128",
                                                   expires: Date().addingTimeInterval(120))
        case "joining": return .joining
        case "ready": return .ready(workspaceName: "Demo Lab")
        case "expired": return .expired
        case "r1": return .alarm(.r1Attack(primaryLabel: primary))
        case "wrongKey": return .alarm(.echoWrongKey)
        case "refused": return .refused(.rejectedOnHost)
        case "denied": return .denied(owner: "5c0574d0")
        case "linkUsed": return .refused(.linkUsed)
        default: return nil
        }
    }
}
