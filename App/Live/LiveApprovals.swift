import Foundation
import OrchClient
import OrchCustody
import OrchProtocol

// B10 phase 1 on a Live workspace: the list of the Mac's approval requests, the recomputed review, and the signature.
extension LiveWorkspace {
    /// `phone.requests`. A read that fails leaves the list as it was shown empty (a request is a wake, never the data); it is never cached
    /// across a failure.
    func refreshApprovals() async {
        guard usable else { return }
        do {
            let list = try await api.phoneRequests()
            guard usable else { return }
            let now = Date()
            setApprovals(list.compactMap { r in
                let expires = Date(timeIntervalSince1970: Double(r.expiresMs) / 1000)
                return expires > now ? ApprovalRequest(id: r.id, workspaceID: info.id, uid: r.uid, ref: r.ref, title: r.title, gate: r.gate, gateGen: r.gateGen, expires: expires) : nil
            })
        } catch {
            setApprovals([])
        }
    }

    func reviewApproval(_ request: ApprovalRequest) async -> ApprovalReviewResult {
        guard usable else { return .failed(ApprovalPhase.notAllowed.message) }
        // the gate is read by the ticket's uid and recomputed: the request's key, title and generation are not used for anything signed
        do {
            let s = try await api.reviewGate(ref: request.uid, gate: request.gate)
            guard usable else { return .failed("This workspace is unavailable.") }
            heldGate = s
            gateRevision += 1
            return .reviewed(ApprovalReviewValue(revision: gateRevision, workspaceID: info.id, gate: s.gate, ticketKey: s.ticketKey, ticketTitle: s.ticketTitle,
                                                 gateGen: s.gateGen, policyWords: s.policyWords, content: s.content))
        } catch where noteKeyAlarm(error) {
            return .failed(Self.keyAlarmMessage)
        } catch GateReviewError.doesNotMatch {
            return .failed("This changed or does not match. Reopen.")
        } catch GateReviewError.cannotSignNow {
            return .failed("This can't be signed right now. Try again later.")
        } catch GateReviewError.notOffered {
            return .failed("Only requirements and plan are approved on the phone.")
        } catch ViewError.writesUnavailable {
            return .failed(ApprovalPhase.notAllowed.message)
        } catch {
            return .failed("The workspace could not be read. Nothing was signed.")
        }
    }

    func decide(_ value: ApprovalReviewValue, choice: ApprovalChoice) async -> ApprovalPhase {
        guard usable, let held = heldGate, value.revision == gateRevision, held.gate == value.gate else { return .invalidated }
        let c: GateChoice
        switch choice {
        case .approve: c = .approve
        case .changes(let text): c = .changes(text: text)
        }
        do {
            let outcome = try await api.decideGate(held, choice: c)
            heldGate = nil
            return await phase(outcome, choice: choice)
        } catch CustodyError.locked {
            api.noteCustodyLocked()
            return .unlockToContinue
        } catch let committed as AnswerCommitted {
            // signed and stored: it exists and is being settled, never "not sent"
            heldGate = nil
            noteKeyAlarm(committed.underlying)
            if let outcome = try? await api.writeOutcome(reviewID: committed.reviewID) { return await phase(outcome, choice: choice) }
            return .checking
        } catch let f as PhoneEvents.Failure {
            switch f {
            case .emptyText: return .textProblem("Write what should change.")
            case .textTooLong: return .textProblem("Too long: at most 4096 bytes.")
            case .text: return .textProblem("The text has a character that can't be sent. Remove it.")
            default: return .notSent("Nothing was signed. Reopen it.")
            }
        } catch ViewError.invalidReview {
            return .invalidated
        } catch ViewError.writesUnavailable {
            return .notAllowed
        } catch where noteKeyAlarm(error) {
            return .notSent(Self.keyAlarmMessage)
        } catch {
            return .notSent("Nothing was signed or stored. Check the connection, then reopen it.")
        }
    }

    private func phase(_ outcome: WriteOutcome, choice: ApprovalChoice) async -> ApprovalPhase {
        let isApprove: Bool = { if case .approve = choice { return true } else { return false } }()
        switch outcome {
        case .landed, .landedAfterResign, .landedUnconfirmed:
            await refresh()
            return isApprove ? .approved : .changesRequested
        case .checking: return .checking
        case .needsReview(.notSent): return .notSent("It was not sent in time. Reopen it.")
        case .needsReview: return .changed
        case .refused(let code):
            switch code {
            case "device.invalid", "not_member", "revoked": return .cannotSign
            case "op.not_allowed", "forbidden_scope": return .notAllowed
            case "gate.stale", "event.bad_base", "gate.status", "gate.incomplete": return .changed
            default: return .notSent("The host refused it. Nothing changed.")
            }
        case .alreadyAnswered, .ticketExists: return .changed
        }
    }
}
