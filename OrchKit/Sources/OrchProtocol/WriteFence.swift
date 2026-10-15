import Foundation

/// A realm's check-and-act gate. `perform` runs `body` only while the realm is current and holds the gate for the whole (synchronous)
/// body, so an invalidation cannot complete between the check and the write. `body` must never suspend. Implemented by
/// `RealmGeneration` (OrchClient); lower layers (store, custody) take it as a protocol so they need not depend on OrchClient.
public protocol WriteFence: AnyObject, Sendable {
    /// Throws when the realm has been invalidated; otherwise runs `body` with invalidation excluded.
    func performFenced<T>(_ body: () throws -> T) throws -> T
}
