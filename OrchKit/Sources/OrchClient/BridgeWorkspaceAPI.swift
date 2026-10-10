import Foundation
import OrchProtocol

/// The App holds this unsigned capability, never the session's package-only signing operations.
public struct BridgeWorkspaceAPI: WorkspaceAPI {
    private let session: WorkspaceSession
    public init(session: WorkspaceSession) { self.session = session }
    public func snapshot() async throws -> WorkspaceSnapshot { try await session.snapshotView() }
    public func review(questionID: ID16) async throws -> QuestionReview { try await session.reviewQuestion(questionID) }
    public func decide(_ review: QuestionReview, optionID: String) async throws -> DecisionOutcome { try await session.submit(review, optionID: optionID) }
    public func pendingDecisions() async -> [DecisionStatus] { await session.pendingDecisions() }
    public func newTicket(_ draft: NewTicketSubmission) async throws -> Ticket { try await session.createTicket(draft) }
    public func events() async -> AsyncStream<WorkspaceEvent> { await session.eventStream() }
}
