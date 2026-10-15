import CryptoKit
import Foundation

/// Section 4: ids derived from keys, pins and the pairing code.
public enum Identifiers {
    static func hash(_ label: String, _ parts: Data...) -> Data {
        Data(SHA256.hash(data: parts.reduce(Data(label.utf8)) { $0 + $1 }))
    }

    /// `person_id = H("orch/v2/id/person|" || suite || pk_pub)[0:16]`
    public static func personID(_ pk: SigningPublicKey) -> ID16 {
        ID16(bytes: hash(Label.hPersonID, Bytes.u8(Suite2.id), pk.x963).prefix(16))!
    }
    /// `device_id = H("orch/v2/id/device|" || suite || dk_sig_pub)[0:16]`
    public static func deviceID(_ dkSig: SigningPublicKey) -> ID16 {
        ID16(bytes: hash(Label.hDeviceID, Bytes.u8(Suite2.id), dkSig.x963).prefix(16))!
    }
    /// `pk_pin`: 32 bytes.
    public static func pkPin(_ pk: SigningPublicKey) -> Data { hash(Label.hPinPerson, Bytes.u8(Suite2.id), pk.x963) }
    /// `wsk_pin`: 32 bytes.
    public static func wskPin(_ wsk: SigningPublicKey) -> Data { hash(Label.hPinWorkspace, Bytes.u8(Suite2.id), wsk.x963) }

    /// The 6-character pairing code (section 4): the first 6 characters of base32 of
    /// `H("orch/v2/sas|" || suite || workspace_id || offer_id || lp16(dk_sig) || lp16(dk_kx) || lp16(wsk) || sas_nonce)`.
    public static func pairingCode(workspace: ID16, offer: ID16, dkSig: SigningPublicKey, dkKx: AgreementPublicKey,
                                   wsk: SigningPublicKey, sasNonce: Data) throws -> String {
        guard sasNonce.count == 32 else { throw CryptoFailure.invalidLength }
        let d = hash(Label.hSAS, Bytes.u8(Suite2.id), workspace.bytes, offer.bytes, Bytes.lp16(dkSig.x963),
                     Bytes.lp16(dkKx.x963), Bytes.lp16(wsk.x963), sasNonce)
        return String(Base32.encode(d).prefix(6))
    }

    /// `cert_code` of the primary's challenge (section 4): `base32(H("orch/v2/sas-cert|" || suite || cj(challenge.o)))[0:6]`.
    /// `dk_hash = H("orch/v2/dk-hash|" || suite || lp16(dk_sig_pub) || lp16(dk_kx_pub))` (32 bytes): both keys of one pairing
    /// attempt (protocol-v2 section 8.4, G3b P3-D28). Travels as b64u.
    public static func dkHash(sig: SigningPublicKey, kx: AgreementPublicKey) -> Data { dkHash(sig: sig.x963, kx: kx.x963) }
    public static func dkHash(sig: Data, kx: Data) -> Data {
        hash(Label.hDKHash, Bytes.u8(Suite2.id), Bytes.lp16(sig), Bytes.lp16(kx))
    }

    /// A pairing attempt nonce: exactly 32 lower-case hex characters (16 CSPRNG bytes; section 8.3 step 2, G3b).
    public static func isAttempt(_ s: String) -> Bool {
        s.utf8.count == 32 && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    public static func certCode(challengeObject: JSONValue) throws -> String {
        String(Base32.encode(hash(Label.hSASCert, Bytes.u8(Suite2.id), try canonicalJSON(challengeObject))).prefix(6))
    }
}

/// Section 2.5: text that a person reads (device names, pairing labels, WebAuthn `shown`) is cleaned by the
/// receiving host. Displaying devices do not clean again. No normalisation.
public enum PersonText {
    public static let maxCodePoints = 80

    /// Removes Cc (except LF), Cf, Zl, Zp, Co, Cn and every Default_Ignorable_Code_Point, then truncates to
    /// 80 code points. The Cn test depends on the Unicode version of the Swift runtime.
    public static func clean(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if u.value == 0x0A { out.append(u); continue }
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned: continue
            default: break
            }
            if u.properties.isDefaultIgnorableCodePoint { continue }
            out.append(u)
            if out.count == maxCodePoints { break }
        }
        return String(out)
    }
}
