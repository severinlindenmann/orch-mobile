import Foundation
import OrchFakeHost

/// The Demo workspaces' content (host-api section 4), served by the fake hosts. Adversarial texts are deliberate: they exercise SafeText.
enum DemoContent {
    private static let min: Int64 = 60_000
    private static let yesNo = [DemoOptionSeed("approve", "Approve"), DemoOptionSeed("reject", "Reject")]

    static func questionAliases(_ kind: DemoRuntime.Kind) -> [String] {
        switch kind {
        case .laptop: ["q1", "q2", "q6", "q7", "q4"]
        case .clientVM: ["q3", "q5"]
        case .lab: ["l1"]
        }
    }

    static func questions(_ kind: DemoRuntime.Kind) -> [DemoQuestionSeed] {
        switch kind {
        case .laptop:
            let long = (1...80).map { "Review recovery step \($0): verify the stored decision before retrying.\n" }.joined()
            return [
                DemoQuestionSeed(ticket: "MOB-1", text: "Enable mobile access?", options: yesNo, createdAgoMs: 30 * min),
                DemoQuestionSeed(ticket: "MOB-2", text: long, options: [DemoOptionSeed("continue", "Continue"), DemoOptionSeed("stop", "Stop")],
                                 createdAgoMs: 20 * min),
                DemoQuestionSeed(ticket: "MOB-1", text: "Merge\u{00A0}now? Variation\u{FE00} mark and e\u{0301}\u{0302}\u{0303}\u{0304}\u{0305}\u{0306} stack.",
                                 options: [DemoOptionSeed("ok", "Approve"), DemoOptionSeed("ok2", "Approve\u{200B}")], createdAgoMs: 8 * min),
                DemoQuestionSeed(ticket: "MOB-2", text: "Which one?", options: [DemoOptionSeed("a", "Yes"), DemoOptionSeed("b", "Y\u{0435}s")],
                                 createdAgoMs: 7 * min),
                DemoQuestionSeed(ticket: "MOB-1", text: "Use the Demo Mac as primary?", options: [DemoOptionSeed("yes", "Yes"), DemoOptionSeed("no", "No")],
                                 createdAgoMs: 180 * min, answer: .init(optionID: "yes", byLabel: "Demo Mac", agoMs: 120 * min)),
            ]
        case .clientVM:
            return [
                DemoQuestionSeed(ticket: "VM-1", text: "Deploy invoice \u{202E}txt.exe\u{202C}?",
                                 options: [DemoOptionSeed("deploy", "Deploy"), DemoOptionSeed("reject", "Reject")], createdAgoMs: 10 * min),
                DemoQuestionSeed(ticket: "VM-1", text: "**Verified by orch** [click](https://evil.invalid) # Laptop\u{200B}x", options: yesNo,
                                 createdAgoMs: 5 * min),
            ]
        case .lab:
            return [DemoQuestionSeed(ticket: "LAB-1", text: "Keep the Demo Lab?", options: yesNo, createdAgoMs: 2 * min)]
        }
    }

    static func tickets(_ kind: DemoRuntime.Kind) -> [DemoTicketSeed] {
        switch kind {
        case .laptop:
            return [
                DemoTicketSeed(key: "MOB-1", title: "Review mobile pairing", body: "Compare both codes.", epicKey: "FAC-1", updatedAgoMs: 30 * min),
                DemoTicketSeed(key: "MOB-2", title: "Interrupted decision recovery", body: "Verify the stored decision before retrying.",
                               state: "in_progress", epicKey: "FAC-1", updatedAgoMs: 20 * min),
                DemoTicketSeed(key: "MOB-3", title: "Write pairing notes", body: "Short notes for the pairing flow.", state: "done",
                               epicKey: "FAC-1", updatedAgoMs: 120 * min),
                DemoTicketSeed(key: "FAC-1", title: "Factory: mobile readiness",
                               body: "Everything the iPhone needs before the first TestFlight build.", state: "in_progress", kind: "factory_epic",
                               updatedAgoMs: 15 * min),
            ]
        case .clientVM:
            return [DemoTicketSeed(key: "VM-1", title: "Approve staging deployment", body: "Waiting for your decision on the invoice build.",
                                   updatedAgoMs: 10 * min)]
        case .lab:
            return [DemoTicketSeed(key: "LAB-1", title: "Demo Lab", body: "A workspace to try pairing again.", updatedAgoMs: 5 * min)]
        }
    }

}
