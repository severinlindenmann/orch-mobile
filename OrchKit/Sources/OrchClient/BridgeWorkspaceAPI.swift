import Foundation
import OrchProtocol

/// The App holds this unsigned capability, never the session's package-only signing operations.
public struct BridgeWorkspaceAPI: WorkspaceAPI {
    private let session: WorkspaceSession
    public init(session: WorkspaceSession) { self.session = session }
    public func start() async { await session.startViews() }
    public func setForeground(_ value: Bool) async { await session.setForeground(value) }
    public func refreshViews() async { await session.refreshViews() }
    public func invalidateReviews() async { await session.invalidateReviews() }
    public func settle(reviewID: String) async throws -> WriteOutcome { try await session.settle(reviewID: reviewID) }
    public var verifiedReceiptMs: Int64? { get async { await session.verifiedReceiptMs } }
    /// - Throws: `StoreError.removalStateUnknown` if removal status cannot be verified.
    ///   Retry when coordination is available; this error does not confirm removal.
    public func snapshot() async throws -> WorkspaceSnapshot { try await session.snapshotView() }
    /// - Throws: `StoreError.removalStateUnknown` if removal status cannot be verified.
    ///   Retry when coordination is available; this error does not confirm removal.
    public func review(questionID: ID16) async throws -> QuestionReview { try await session.reviewQuestion(questionID) }
    /// - Throws: `StoreError.removalStateUnknown` if removal status cannot be verified.
    ///   Retry when coordination is available; this error does not confirm removal.
    public func answer(_ snapshot: ReviewedSnapshot, option: String) async throws -> WriteOutcome { try await session.answer(snapshot, option: option) }
    /// - Throws: `StoreError.removalStateUnknown` if removal status cannot be verified.
    ///   Retry when coordination is available; this error does not confirm removal.
    public func pendingWrites() async throws -> [WriteStatus] { try await session.pendingWrites() }
    public func writesAvailable() async -> Bool { await session.writesAvailable() }
    public func noteInactive() async { await session.noteInactive() }
    public func noteProtectedDataUnavailable() async { await session.noteProtectedDataUnavailable() }
    /// - Throws: `StoreError.removalStateUnknown` if removal status cannot be verified.
    ///   Retry when coordination is available; this error does not confirm removal.
    public func newTicket(_ draft: NewTicketSubmission) async throws -> Ticket { try await session.createTicket(draft) }
    public func events() async -> AsyncStream<WorkspaceEvent> { await session.eventStream() }
    public func keyAlarm() async -> WorkspaceKeyAlarm? { await session.keyAlarm() }
}
