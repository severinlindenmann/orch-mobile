import Foundation
import OrchProtocol

/// The App holds this unsigned capability, never the session's package-only signing operations.
public struct BridgeWorkspaceAPI: WorkspaceAPI {
    private let session: WorkspaceSession
    public init(session: WorkspaceSession) { self.session = session }
    public func start() async { await session.startViews() }
    /// Going to the background ends every ticket synchronously first (the fence), then the session actor catches up.
    public func setForeground(_ value: Bool) async {
        if !value { session.noteBackground() }
        await session.setForeground(value)
    }
    public func refreshViews() async { await session.refreshViews() }
    public func invalidateReviews() async {
        session.noteReviewsInvalidated()
        await session.invalidateReviews()
    }
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
    public func writeOutcome(reviewID: String) async throws -> WriteOutcome? { try await session.writeOutcome(reviewID: reviewID) }
    public func writesAvailable() async -> Bool { await session.writesAvailable() }
    public func writesAvailable(op: String) async -> Bool { await session.writesAvailable(op: op) }
    public func reviewCreation(type: String, title: String) async throws -> CreationReview { try await session.reviewCreation(type: type, title: title) }
    public func create(_ review: CreationReview, disclosedKey: String?) async throws -> WriteOutcome {
        try await session.create(review, disclosedKey: disclosedKey)
    }
    #if DEBUG && targetEnvironment(simulator)
    public func devSandboxStatus() async -> DevSandboxStatus { await session.devSandboxStatus() }
    public func devSandboxCheck() async -> DevSandboxCheck { await session.devSandboxCheck() }
    #endif
    public func noteInactive() { session.noteInactive() }
    public func noteProtectedDataUnavailable() { session.noteProtectedDataUnavailable() }
    public func noteCustodyLocked() { session.noteCustodyLocked() }
    public func noteBackground() { session.noteBackground() }
    public func noteReviewsInvalidated() { session.noteReviewsInvalidated() }
    public func events() async -> AsyncStream<WorkspaceEvent> { await session.eventStream() }
    public func keyAlarm() async -> WorkspaceKeyAlarm? { await session.keyAlarm() }
    #if DEBUG
    /// Tests only (App tests): counts the session's hook points (`pe.sign` is the person-event signature) and its stored attempts.
    public func debugSetHook(_ h: (@Sendable (String) throws -> Void)?) async { await session.setCrashHook(h) }
    public func debugAttemptCount() async throws -> Int { try await session.debugAttemptCount() }
    #endif
}
