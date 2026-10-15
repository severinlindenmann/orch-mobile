import Foundation
import OrchCustody
import OrchProtocol

/// A signing handle that dies with its realm lifetime: after `RealmContext.invalidate` (or `DemoSetup.reset`) every use throws `staleGeneration`.
package struct LeasedSigner: Signer {
    package let inner: any Signer
    package let generation: RealmGeneration
    package var publicKey: SigningPublicKey { inner.publicKey }
    package func rawSignature(over message: Data) throws -> Data { try generation.perform { try inner.rawSignature(over: message) } }
}

package struct LeasedKeyAgreer: KeyAgreer {
    package let inner: any KeyAgreer
    package let generation: RealmGeneration
    package var publicKey: AgreementPublicKey { inner.publicKey }
    package func sharedSecret(with peer: AgreementPublicKey) throws -> Data { try generation.perform { try inner.sharedSecret(with: peer) } }
}

