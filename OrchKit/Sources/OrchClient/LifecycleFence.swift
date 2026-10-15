import Foundation
import Synchronization

/// The C2b lifecycle invariant, in one place:
///
/// **A person-event signature, and the first dispatch of an attempt, happen only while the lifecycle is still valid at the moment of
/// the effect.**
///
/// "Valid" means: the app is in the foreground, the custody has not reported a lock and protected data is available, and nothing has
/// invalidated the lifecycle since the caller made its checks. Every invalidation (background, `.inactive`, protected-data loss, a custody
/// lock, `invalidateReviews`, a realm or generation change, an `ensureCurrent` failure) bumps the epoch SYNCHRONOUSLY, under a lock, from
/// whatever thread reports it: nothing waits for the session actor. Callers capture a `Ticket` at their checks and re-validate it
/// synchronously right before the effect:
///   1. inside the signing transaction body, immediately before `PhoneEvents.sign`;
///   2. in `post`, after its last suspension and immediately before `bridgePost`, for an attempt not yet dispatched.
/// A ticket of a review also carries that review's eligibility token (codex 11): issued at the Sign tap, in memory only, removed by every
/// invalidation. An automatic re-sign, and the first dispatch of an automatic attempt, need it.
package final class LifecycleFence: Sendable {
    package struct Ticket: Sendable, Equatable {
        let epoch: UInt64
        let review: String?
        let token: UUID?
    }

    package enum Invalidation: Sendable {
        case background, inactive, protectedDataLost, custodyLocked, reviewsInvalidated, generationEnded, realmClosed
    }

    private struct State {
        var epoch: UInt64 = 0
        var foreground = true, unlocked = true, protectedData = true, closed = false
        var eligibility: [String: UUID] = [:]
        var usable: Bool { foreground && unlocked && protectedData && !closed }
    }

    private let state = Mutex(State())

    package init() {}

    /// Ends every ticket issued so far (and every eligibility token).
    package func invalidate(_ why: Invalidation) {
        state.withLock { s in
            s.epoch &+= 1
            s.eligibility.removeAll()
            switch why {
            case .background: s.foreground = false
            case .protectedDataLost: s.protectedData = false
            case .custodyLocked: s.unlocked = false
            case .realmClosed: s.closed = true
            case .inactive, .reviewsInvalidated, .generationEnded: break
            }
        }
    }

    /// Back in the foreground (the device is unlocked, protected data is available again). Never re-validates an old ticket.
    package func foregrounded() { state.withLock { $0.foreground = true; $0.unlocked = true; $0.protectedData = true } }
    /// A new review read after a custody lock: the person is back (the way back from a lock is a new review, U7).
    package func reviewedAgain() { state.withLock { if $0.foreground && $0.protectedData { $0.unlocked = true } } }

    /// A plain ticket (no review token), only while the lifecycle is usable.
    package func ticket() -> Ticket? { state.withLock { $0.usable ? Ticket(epoch: $0.epoch, review: nil, token: nil) : nil } }

    /// Issues the review's eligibility token (the Sign tap) and a ticket bound to it.
    package func issue(review: String) -> Ticket? {
        state.withLock { s in
            guard s.usable else { return nil }
            let t = UUID()
            s.eligibility[review] = t
            return Ticket(epoch: s.epoch, review: review, token: t)
        }
    }

    /// A ticket bound to the review's CURRENT eligibility token; nil without one.
    package func ticket(review: String) -> Ticket? {
        state.withLock { s in
            guard s.usable, let t = s.eligibility[review] else { return nil }
            return Ticket(epoch: s.epoch, review: review, token: t)
        }
    }

    /// The synchronous last-moment check: the same epoch, still usable, and the review's token unchanged.
    package func valid(_ t: Ticket) -> Bool {
        state.withLock { s in
            guard s.usable, s.epoch == t.epoch else { return false }
            if let review = t.review { return s.eligibility[review] == t.token }
            return true
        }
    }

    package func revoke(review: String) { state.withLock { _ = $0.eligibility.removeValue(forKey: review) } }
    package func hasEligibility(review: String) -> Bool { state.withLock { $0.eligibility[review] != nil } }
}
