import Foundation
import OrchProtocol

/// Field readers for exact-field-set checks in the client (OrchProtocol's own are internal to it).
extension Dictionary where Key == String, Value == JSONValue {
    /// Every key is ASCII (section 2.3) before the set is compared byte-exactly (Swift `Set<String>` equality is canonical equivalence).
    package func exactly(_ keys: Set<String>) -> Bool {
        self.keys.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { $0 < 0x80 } } && Set(self.keys) == keys
    }
    package func idField(_ k: String) -> ID16? { self[k]?.string.flatMap { ID16(hex: $0) } }
    package func b64uField(_ k: String, length: Int? = nil) -> Data? { self[k]?.string.flatMap { B64U.decode($0, length: length) } }
    package func u32Field(_ k: String) -> UInt32? { self[k]?.int.flatMap { $0 >= 1 && $0 <= Int64(UInt32.max) ? UInt32($0) : nil } }
    package func sigKeyField(_ k: String) -> SigningPublicKey? {
        b64uField(k, length: Suite2.publicKeyLength).flatMap { try? SigningPublicKey(x963: $0) }
    }
    package func kxKeyField(_ k: String) -> AgreementPublicKey? {
        b64uField(k, length: Suite2.publicKeyLength).flatMap { try? AgreementPublicKey(x963: $0) }
    }
}

extension String {
    package func utf8Equal(_ other: String) -> Bool { utf8.elementsEqual(other.utf8) }
}
