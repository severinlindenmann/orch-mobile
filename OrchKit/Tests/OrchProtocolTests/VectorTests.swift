import CryptoKit
import Foundation
import Testing
@testable import OrchProtocol

// TODO(later slices): suite-2 vector groups that need a host or coordinator pipeline, deliberately not run here.
//   bridge.host_cases (47)      slice 2a: FakeHost ordered checks, replay, quota, budgets, epochs, seq window
//   bridge.pair_answers (20)    slice 2b: open_pair_answer / PairingCoordinator (pins, SAS, R1 alarm, cert_pending UI rules)
//   bridge.links (6)            slice 2b: pairing link fragment parsing
//   enroll, webauthn            slice 2b / later: scoped agent enrolment, assertion and registration challenges
//   revocation_op               slice 2a: the host's bridge op for a PK-signed revocation
//   ws_envelopes, publish       out of scope for the phone (ws->ws, orch-publish)
//   relay_auth.cases            covered here only as the relay-side pure check (RelayAuth.check); the HTTP flow is slice 1
//   reader slice                persist the highest version seen per document and treat a lower "latest" as an error (section 10.6);
//                               DropDocument.verifyChain/checkPut are pure and hold no such state
// The ed25519_small_order group and everything under suites."1" belong to suite 1, which this module does not implement.
// Slice 0 gates run in BridgeTests, CardMembershipTests, CertRequestTests and DropTests: bridge.seal, bridge.device_cases,
// card.cases/hosted_marker/card_key_wrap_to_phone, member_lists, wk_grants.cases, cert_request.* , relay_auth.cases, drop.*.

@Suite struct VectorTests {
    var s2: JSONValue { Vectors.suite2 }

    @Test func labelsMatchTheVectors() {
        let l = Vectors.root["labels"].object!
        let mine: [String: String] = [
            "kdf_bridge": Label.kdfBridge,
            "kdf_bridge_msg": Label.kdfBridgeMsg,
            "kdf_push": Label.kdfPush,
            "kdf_push_msg": Label.kdfPushMsg,
            "kdf_wrap_wk": Label.kdfWrapWK,
            "kdf_wrap_sk": Label.kdfWrapSK,
            "kdf_wrap_msg": Label.kdfWrapMsg,
            "kdf_pair": Label.kdfPair,
            "kdf_seal": Label.kdfSeal,
            "kdf_card": Label.kdfCard,
            "kdf_drop_content": Label.kdfDropContent,
            "kdf_drop_meta": Label.kdfDropMeta,
            "kdf_label": Label.kdfLabel,
            "kdf_label_msg": Label.kdfLabelMsg,
            "aad_seal": Label.aadSeal,
            "aad_push": Label.aadPush,
            "aad_wrap": Label.aadWrap,
            "aad_card": Label.aadCard,
            "aad_label": Label.aadLabel,
            "aad_drop_meta": Label.aadDropMeta,
            "sig_device_cert": Label.sigDeviceCert,
            "sig_revocation": Label.sigRevocation,
            "sig_card_wsk": Label.sigCardWSK,
            "sig_ws_delegation": Label.sigWSDelegation,
            "sig_cert_challenge": Label.sigCertChallenge,
            "sig_cert_rejection": Label.sigCertRejection,
            "sig_push": Label.sigPush,
            "sig_decision": Label.sigDecision,
            "sig_member_list": Label.sigMemberList,
            "sig_wk_grant": Label.sigWKGrant,
            "sig_sk_grant": Label.sigSKGrant,
            "sig_bridge": Label.sigBridge,
            "sig_cert_request": Label.sigCertRequest,
            "sig_enroll_request": Label.sigEnrollRequest,
            "sig_drop_object": Label.sigDropObject,
            "sig_drop_claim": Label.sigDropClaim,
            "sig_ws_envelope": Label.sigWSEnvelope,
            "sig_ws_cosign": Label.sigWSCosign,
            "sig_webauthn_bind": Label.sigWebAuthnBind,
            "sig_relay_auth": Label.sigRelayAuth,
            "sig_publish": Label.sigPublish,
            "h_device_id": Label.hDeviceID,
            "h_person_id": Label.hPersonID,
            "h_pin_person": Label.hPinPerson,
            "h_pin_workspace": Label.hPinWorkspace,
            "h_sas": Label.hSAS,
            "h_sas_cert": Label.hSASCert,
            "h_dk_hash": Label.hDKHash,
            "h_dek_commit": Label.hDEKCommit,
            "h_card_key_commit": Label.hCardKeyCommit,
            "h_wk_commit": Label.hWKCommit,
            "h_drop_parent": Label.hDropParent,
            "h_ws_envelope": Label.hWSEnvelope,
            "h_question": Label.hQuestion,
            "h_assert": Label.hAssert,
            "h_webauthn_reg": Label.hWebAuthnReg,
            "mac_enroll": Label.macEnroll
        ]
        // F1 (ticket log) labels from orch-relay #32. The phone neither writes nor verifies ticket or workspace event
        // logs, checkpoints or gate hashes (host/relay side, docs/gaps.md #25), so OrchProtocol has no `Label.*` for them.
        let knownNotUsedByThePhone: Set<String> = [
            "sig_ticket_event", "sig_ws_event", "sig_host_event", "sig_checkpoint",
            "h_section", "h_value", "h_gate", "h_policy", "h_people", "h_question_id", "h_event", "h_grant_secret",
            "h_checkpoint", "sig_genesis_pin", "h_log_acc"
        ]
        #expect(knownNotUsedByThePhone.count == 15)
        #expect(knownNotUsedByThePhone.isDisjoint(with: Set(mine.keys)))
        #expect(Set(l.keys) == Set(mine.keys).union(knownNotUsedByThePhone))
        for (k, v) in l where !knownNotUsedByThePhone.contains(k) { #expect(mine[k] == v.str, "\(k)") }
    }

    @Test func signAndAADLabelsArePrefixFree() {
        let all = [Label.sigDeviceCert, Label.sigRevocation, Label.sigCardWSK, Label.sigWSDelegation, Label.sigCertChallenge, Label.sigCertRejection,
                   Label.sigPush, Label.sigDecision, Label.sigMemberList, Label.sigWKGrant, Label.sigSKGrant, Label.sigBridge,
                   Label.sigCertRequest, Label.sigEnrollRequest, Label.sigDropObject, Label.sigDropClaim, Label.sigWSEnvelope,
                   Label.sigWSCosign, Label.sigWebAuthnBind, Label.sigRelayAuth, Label.sigPublish,
                   Label.aadSeal, Label.aadPush, Label.aadWrap, Label.aadCard, Label.aadLabel, Label.aadDropMeta,
                   Label.hDeviceID, Label.hPersonID, Label.hPinPerson, Label.hPinWorkspace, Label.hSAS, Label.hSASCert, Label.hDKHash,
                   Label.hDEKCommit, Label.hCardKeyCommit, Label.hDropParent, Label.hWSEnvelope, Label.hQuestion,
                   Label.hAssert, Label.hWebAuthnReg, Label.macEnroll]
        for a in all {
            #expect(a.hasSuffix("|") && a.hasPrefix("orch/v2/"), "\(a)")
            for b in all where a != b { #expect(!b.hasPrefix(a), "\(a) prefixes \(b)") }
        }
        #expect(Set(all).count == all.count)
    }

    @Test func constants() {
        let c = Vectors.root["constants"]
        #expect(c["seal_purposes"].items.map(\.str) == SealPurpose.allCases.map(\.rawValue))
        #expect(c["scope_order"].items.map(\.str) == Scopes.order)
        #expect(c["skew_ms"].i64 == Suite2.skewMs)
    }

    @Test func seedsReproduceEveryVectorPublicKey() throws {
        let keys = s2["keys"].object!
        #expect(keys.count == 20)
        for (name, k) in keys {
            let pub = name.hasSuffix(".kx") ? try testAgreer(name).publicKey.x963 : try testSigner(name).publicKey.x963
            #expect(pub == k["pub"].hexData, "\(name)")
        }
    }

    @Test func idsPinsAndSAS() throws {
        let ids = s2["ids"]
        func pub(_ n: String) -> SigningPublicKey { s2["keys"][n]["pub"].sigPub }
        #expect(Identifiers.personID(pub("person_alice.sig")) == ids["person_alice"].id)
        #expect(Identifiers.personID(pub("person_bob.sig")) == ids["person_bob"].id)
        for (dev, key) in [("device_primary", "primary.sig"), ("device_phone", "phone.sig"), ("device_laptop", "laptop.sig"),
                           ("device_intruder", "intruder.sig"), ("device_agent", "agent.sig"), ("device_bob_phone", "bob_phone.sig")] {
            #expect(Identifiers.deviceID(pub(key)) == ids[dev].id, "\(dev)")
        }
        #expect(Identifiers.pkPin(pub("person_alice.sig")) == ids["pk_pin_alice"].hexData)
        #expect(Identifiers.wskPin(pub("wsk_a.sig")) == ids["wsk_pin_a"].hexData)
        #expect(Identifiers.pkPin(pub("person_alice.sig")) != Identifiers.wskPin(pub("person_alice.sig")))

        let sas = s2["bridge"]["sas"]
        let code = try Identifiers.pairingCode(workspace: sas["workspace"].id, offer: sas["offer"].id, dkSig: sas["dk_sig_pub"].sigPub,
                                               dkKx: sas["dk_kx_pub"].kxPub, wsk: sas["wsk_pub"].sigPub, sasNonce: sas["sas_nonce"].hexData)
        #expect(code == sas["code"].str)
        #expect(code.count == 6 && code.allSatisfy { ("A"..."Z").contains($0) || ("2"..."7").contains($0) })
        // the code binds every input
        let other = try Identifiers.pairingCode(workspace: sas["workspace"].id, offer: sas["offer"].id, dkSig: sas["dk_sig_pub"].sigPub,
                                                dkKx: sas["dk_kx_pub"].kxPub, wsk: sas["wsk_pub"].sigPub,
                                                sasNonce: Data(repeating: 1, count: 32))
        #expect(other != code)
        #expect(throws: CryptoFailure.self) {
            try Identifiers.pairingCode(workspace: sas["workspace"].id, offer: sas["offer"].id, dkSig: sas["dk_sig_pub"].sigPub,
                                        dkKx: sas["dk_kx_pub"].kxPub, wsk: sas["wsk_pub"].sigPub, sasNonce: Data(count: 31))
        }
    }

    @Test func signVectors() throws {
        let cases = s2["sign"].items
        #expect(cases.count == 8)
        for c in cases {
            let name = c["name"].str
            let got: Bool
            // point_not_on_curve: an off-curve key cannot even be constructed, so it is refused before any verify
            // (asserted separately below); every other case reaches Signature.verify.
            if let pub = try? SigningPublicKey(x963: c["pub"].hexData) {
                got = Signature.verify(pub, signature: c["sig"].hexData, message: c["msg"].hexData)
            } else { got = false }                                           // point_not_on_curve never reaches verify
            #expect(got == c["valid"].bool, "\(name)")
        }
        // the malleable twin shares r and has a different, high s
        let twin = cases.first { $0["name"].str == "high_s_twin_verifies" }!, valid = cases.first { $0["name"].str == "valid" }!
        #expect(twin["sig"].hexData.prefix(32) == valid["sig"].hexData.prefix(32))
        #expect(twin["sig"].hexData.suffix(32) != valid["sig"].hexData.suffix(32))
        // off-curve keys are refused at construction
        #expect(throws: CryptoFailure.self) { try SigningPublicKey(x963: cases.last!["pub"].hexData) }
        #expect(throws: CryptoFailure.self) { try SigningPublicKey(x963: Data(count: 65)) }
        #expect(throws: CryptoFailure.self) { try SigningPublicKey(x963: valid["pub"].hexData.dropFirst()) }
    }

    @Test func signAndVerifyRoundTrip() throws {
        let s = SoftwareSigner()
        let sig = try Signature.sign(s, label: Label.sigPush, message: Data("m".utf8))
        #expect(sig.count == 64)
        #expect(Signature.verify(s.publicKey, signature: sig, label: Label.sigPush, message: Data("m".utf8)))
        #expect(!Signature.verify(s.publicKey, signature: sig, label: Label.sigDecision, message: Data("m".utf8)))   // domain separation
        #expect(!Signature.verify(s.publicKey, signature: sig, label: Label.sigPush, message: Data("n".utf8)))
        #expect(!Signature.verify(SoftwareSigner().publicKey, signature: sig, label: Label.sigPush, message: Data("m".utf8)))
        var bad = sig; bad[10] ^= 1
        #expect(!Signature.verify(s.publicKey, signature: bad, label: Label.sigPush, message: Data("m".utf8)))
        #expect(!Signature.verify(s.publicKey, signature: sig.dropLast(), label: Label.sigPush, message: Data("m".utf8)))
    }

    @Test func hkdfVectors() throws {
        let cases = s2["hkdf"].items
        #expect(cases.count == 10)
        for c in cases {
            let name = c["name"].str
            // generic: info bytes and info_text agree, and HKDF reproduces okm
            #expect(c["info"].hexData == Data(c["info_text"].str.utf8), "\(name) info")
            let okm = KDF.hkdf(ikm: c["ikm"].key, salt: c["salt"].hexData, info: c["info"].hexData).rawBytes
            #expect(okm == c["okm"].hexData, "\(name)")
        }
        // typed derivations
        let ws = s2["ids"]["workspace_a"].id, space = s2["ids"]["shared_space"].id
        func ikm(_ n: String) -> SymmetricKey { cases.first { $0["name"].str == n }!["ikm"].key }
        func okm(_ n: String) -> Data { cases.first { $0["name"].str == n }!["okm"].hexData }
        #expect(KDF.kBridge(wk: ikm("k_bridge_epoch_1"), workspace: ws, epoch: 1).rawBytes == okm("k_bridge_epoch_1"))
        #expect(KDF.kBridge(wk: ikm("k_bridge_epoch_2"), workspace: ws, epoch: 2).rawBytes == okm("k_bridge_epoch_2"))
        #expect(KDF.kPush(wk: ikm("k_push_epoch_1"), workspace: ws, epoch: 1).rawBytes == okm("k_push_epoch_1"))
        #expect(KDF.kWrapWK(wk: ikm("k_wrap_wk_epoch_1"), workspace: ws, epoch: 1).rawBytes == okm("k_wrap_wk_epoch_1"))
        #expect(KDF.kWrapSK(sk: ikm("k_wrap_sk_epoch_1"), space: space, epoch: 1).rawBytes == okm("k_wrap_sk_epoch_1"))
        let offer = s2["bridge"]["sas"]["offer"].id
        #expect(KDF.kPair(secret: ikm("k_pair"), workspace: ws, offer: offer).rawBytes == okm("k_pair"))
        #expect(KDF.kCard(ck: ikm("k_card_seq_1"), workspace: ws, cardSeq: 1).rawBytes == okm("k_card_seq_1"))
        let dropInfo = cases.first { $0["name"].str == "k_drop_content_v1" }!["info_text"].str.split(separator: "|")
        #expect(KDF.kDropContent(dek: ikm("k_drop_content_v1"), object: ID16(hex: String(dropInfo[1]))!, version: 1).rawBytes == okm("k_drop_content_v1"))
        #expect(KDF.kLabel(pvk: ikm("k_label"), person: s2["ids"]["person_alice"].id).rawBytes == okm("k_label"))
        let msg = cases.first { $0["name"].str == "k_msg_bridge" }!
        #expect(KDF.messageKey(base: msg["ikm"].key, salt: msg["salt"].hexData, msgLabel: Label.kdfBridgeMsg).rawBytes == okm("k_msg_bridge"))
        // a different epoch or workspace gives an unrelated key
        #expect(KDF.kPush(wk: ikm("k_push_epoch_1"), workspace: ws, epoch: 2).rawBytes != okm("k_push_epoch_1"))
        #expect(KDF.kPush(wk: ikm("k_push_epoch_1"), workspace: space, epoch: 1).rawBytes != okm("k_push_epoch_1"))
    }

    @Test func saltedAEADVector() throws {
        let c = s2["salted_aead"][0]
        let sealed = try SaltedAEAD.seal(key: c["k_base"].key, msgLabel: c["msg_label"].str, aad: c["aad"].hexData,
                                         plaintext: c["plaintext"].hexData, salt: c["salt"].hexData)
        #expect(sealed == c["sealed"].hexData)
        #expect(KDF.messageKey(base: c["k_base"].key, salt: c["salt"].hexData, msgLabel: c["msg_label"].str).rawBytes == c["k_msg"].hexData)
        #expect(try SaltedAEAD.open(key: c["k_base"].key, msgLabel: c["msg_label"].str, aad: c["aad"].hexData, blob: sealed) == c["plaintext"].hexData)
    }

    @Test func saltedAEADNegatives() throws {
        let k = SymmetricKey(size: .bits256), aad = Data("aad".utf8), pt = Data("hello".utf8)
        let a = try SaltedAEAD.seal(key: k, msgLabel: "l", aad: aad, plaintext: pt)
        let b = try SaltedAEAD.seal(key: k, msgLabel: "l", aad: aad, plaintext: pt)
        #expect(a != b)                                                         // fresh salt per seal
        #expect(a.count == 16 + pt.count + 16)
        #expect(try SaltedAEAD.open(key: k, msgLabel: "l", aad: aad, blob: a) == pt)
        #expect(throws: CryptoFailure.self) { try SaltedAEAD.open(key: k, msgLabel: "m", aad: aad, blob: a) }
        #expect(throws: CryptoFailure.self) { try SaltedAEAD.open(key: k, msgLabel: "l", aad: Data("x".utf8), blob: a) }
        #expect(throws: CryptoFailure.self) { try SaltedAEAD.open(key: SymmetricKey(size: .bits256), msgLabel: "l", aad: aad, blob: a) }
        for i in [0, 15, 16, a.count - 1] {
            var t = a; t[i] ^= 1
            #expect(throws: CryptoFailure.self) { try SaltedAEAD.open(key: k, msgLabel: "l", aad: aad, blob: t) }
        }
        #expect(throws: CryptoFailure.self) { try SaltedAEAD.open(key: k, msgLabel: "l", aad: aad, blob: a.prefix(31)) }
        #expect(throws: CryptoFailure.self) { try SaltedAEAD.open(key: k, msgLabel: "l", aad: aad, blob: Data()) }
        #expect(throws: CryptoFailure.self) { try SaltedAEAD.seal(key: k, msgLabel: "l", aad: aad, plaintext: pt, salt: Data(count: 15)) }
    }

    @Test func sealVectorsReproduce() throws {
        let cases = s2["seal"].items
        #expect(cases.count == 1)
        for c in cases {
            let eph = try SoftwareKeyAgreer(testScalar: scalar(fromSeed: c["eph_seed"].hexData))
            #expect(eph.publicKey.x963 == c["eph_pub"].hexData)
            let rcpt = c["recipient_kx_pub"].kxPub
            #expect(try eph.sharedSecret(with: rcpt) == c["shared_secret"].hexData)
            let purpose = SealPurpose(rawValue: c["purpose"].str)!
            #expect(Sealing.aad(purpose: purpose, object: c["object_id"].id, epoch: c["epoch"].u32, extra: c["extra_aad"].hexData) == c["aad"].hexData)
            #expect(Sealing.key(sharedSecret: c["shared_secret"].hexData, ephPub: eph.publicKey.x963, recipientPub: rcpt.x963,
                                purpose: purpose, recipientID: c["recipient_id"].id).rawBytes == c["key"].hexData)
            let sealed = try Sealing.seal(ephemeral: eph, to: rcpt, recipientID: c["recipient_id"].id, purpose: purpose,
                                          object: c["object_id"].id, epoch: c["epoch"].u32, extra: c["extra_aad"].hexData,
                                          plaintext: c["plaintext"].hexData)
            #expect(sealed == c["sealed"].hexData)
        }
    }

    @Test func sealOpenVectors() throws {
        let cases = s2["seal_open"].items
        #expect(cases.count == 7)
        for c in cases {
            let recipient = try testAgreer("\(c["recipient"].str).kx")
            let name = c["name"].str
            do {
                let got = try Sealing.open(with: recipient, recipientID: c["recipient_id"].id,
                                           purpose: SealPurpose(rawValue: c["purpose"].str)!, object: c["object_id"].id,
                                           epoch: c["epoch"].u32, sealed: c["sealed"].hexData)
                #expect(!c["plaintext"].isNull, "\(name) must not open")
                #expect(got == c["plaintext"].hexData, "\(name)")
            } catch {
                #expect(c["plaintext"].isNull, "\(name) must open")
                #expect(error as? CryptoFailure == .authenticationFailed, "\(name)")
            }
        }
    }

    @Test func sealRoundTripAndNegatives() throws {
        let rcpt = SoftwareKeyAgreer(), rid = ID16.random(), obj = ID16.random(), pt = Data("secret".utf8)
        for purpose in SealPurpose.allCases {
            let a = try Sealing.seal(to: rcpt.publicKey, recipientID: rid, purpose: purpose, object: obj, epoch: 7, extra: Data([1, 2]), plaintext: pt)
            let b = try Sealing.seal(to: rcpt.publicKey, recipientID: rid, purpose: purpose, object: obj, epoch: 7, extra: Data([1, 2]), plaintext: pt)
            #expect(a != b && a.prefix(65) != b.prefix(65))                      // a fresh ephemeral key every seal
            #expect(a.count == 65 + pt.count + 16)
            #expect(try Sealing.open(with: rcpt, recipientID: rid, purpose: purpose, object: obj, epoch: 7, extra: Data([1, 2]), sealed: a) == pt)
            #expect(throws: CryptoFailure.self) { try Sealing.open(with: rcpt, recipientID: rid, purpose: purpose, object: obj, epoch: 7, extra: Data([1, 3]), sealed: a) }
            #expect(throws: CryptoFailure.self) { try Sealing.open(with: rcpt, recipientID: rid, purpose: purpose, object: obj, epoch: 8, extra: Data([1, 2]), sealed: a) }
            #expect(throws: CryptoFailure.self) { try Sealing.open(with: SoftwareKeyAgreer(), recipientID: rid, purpose: purpose, object: obj, epoch: 7, extra: Data([1, 2]), sealed: a) }
        }
        let a = try Sealing.seal(to: rcpt.publicKey, recipientID: rid, purpose: .wk, object: obj, epoch: 1, plaintext: pt)
        #expect(throws: CryptoFailure.self) { try Sealing.open(with: rcpt, recipientID: rid, purpose: .wk, object: obj, epoch: 1, sealed: a.prefix(80)) }
        var junk = a; junk[1] ^= 1                                               // off-curve ephemeral key
        #expect(throws: CryptoFailure.self) { try Sealing.open(with: rcpt, recipientID: rid, purpose: .wk, object: obj, epoch: 1, sealed: junk) }
    }

    @Test func sealedLabelVector() throws {
        let c = s2["label_sealed"]
        let person = s2["ids"]["person_alice"].id
        let sealed = try SealedLabel.seal(label: c["label"].str, pvk: c["pvk"].key, person: person, device: c["device_id"].id, salt: c["salt"].hexData)
        #expect(B64U.encode(sealed) == c["sealed"].str)
        #expect(SealedLabel.aad(device: c["device_id"].id) == c["aad"].hexData)
        #expect(try SealedLabel.open(sealed: c["sealed"].b64Data, pvk: c["pvk"].key, person: person, device: c["device_id"].id) == "phone")
        #expect(throws: CryptoFailure.self) { try SealedLabel.open(sealed: c["sealed"].b64Data, pvk: SymmetricKey(size: .bits256), person: person, device: c["device_id"].id) }
        #expect(throws: CryptoFailure.self) { try SealedLabel.open(sealed: c["sealed"].b64Data, pvk: c["pvk"].key, person: person, device: ID16.random()) }
        #expect(throws: CryptoFailure.self) { try SealedLabel.open(sealed: c["sealed"].b64Data, pvk: c["pvk"].key, person: ID16.random(), device: c["device_id"].id) }
        let bom = try SealedLabel.seal(label: "\u{FEFF}x", pvk: c["pvk"].key, person: person, device: c["device_id"].id)
        #expect(try SealedLabel.open(sealed: bom, pvk: c["pvk"].key, person: person, device: c["device_id"].id).unicodeScalars.count == 2)
        let again = try SealedLabel.seal(label: "x", pvk: c["pvk"].key, person: person, device: c["device_id"].id)
        #expect(try SealedLabel.open(sealed: again, pvk: c["pvk"].key, person: person, device: c["device_id"].id) == "x")
    }

    @Test func certificateVectors() throws {
        let cases = s2["certs"]["cases"].items
        #expect(cases.count == 16)
        var accepted = 0
        for c in cases {
            let name = c["name"].str
            if name == "valid" { #expect(Data(Label.sigDeviceCert.utf8) + (try canonicalJSON(c["signed"]["o"])) == c["signed_bytes"].hexData) }
            let revoked = Set(c["revoked"].items.map(\.id))
            do {
                let cert = try DeviceCertificate.verify(c["signed"], personKey: c["pk_pub"].sigPub, nowMs: c["now_ms"].i64, revoked: revoked)
                #expect(!c["expect"]["ok"].isNull, "\(name) accepted")
                accepted += 1
                #expect(cert.deviceID.hex == c["expect"]["ok"]["device_id"].str, "\(name)")
                #expect(cert.scopesMax == c["expect"]["ok"]["scopes_max"].items.map(\.str), "\(name)")
                #expect(cert.expiresMs == c["expect"]["ok"]["expires_ms"].int, "\(name)")
            } catch let r as Refusal {
                #expect(r.rawValue == c["expect"]["refuse"].str, "\(name)")
            }
        }
        #expect(accepted == 4)
    }

    @Test func certificateBuiltBySigner() throws {
        let pk = SoftwareSigner(), dk = SoftwareSigner(), kx = SoftwareKeyAgreer()
        let o: [String: JSONValue] = [
            "v": 2, "suite": 2, "kind": "device_cert", "device_id": .string(Identifiers.deviceID(dk.publicKey).hex),
            "person_id": .string(Identifiers.personID(pk.publicKey).hex), "dk_sig_pub": .string(B64U.encode(dk.publicKey.x963)),
            "dk_kx_pub": .string(B64U.encode(kx.publicKey.x963)), "label_sealed": .string(B64U.encode(Data(count: 40))),
            "created_ms": 1000, "expires_ms": .null, "scopes_max": ["look", "decide"]]
        let signed = try SignedObject.sign(o, kind: .deviceCert, signer: pk)
        let cert = try DeviceCertificate.verify(signed.json, personKey: pk.publicKey, nowMs: 2000)
        #expect(cert.scopesMax == ["look", "decide"] && cert.signingKey == dk.publicKey && cert.agreementKey == kx.publicKey)
        #expect(throws: Refusal.certInvalid) { try DeviceCertificate.verify(signed.json, personKey: SoftwareSigner().publicKey, nowMs: 2000) }
        #expect(throws: Refusal.revoked) { try DeviceCertificate.verify(signed.json, personKey: pk.publicKey, nowMs: 2000, revoked: [cert.deviceID]) }
        #expect(throws: Refusal.malformed) { try SignedObject.sign(["v": 1, "suite": 2, "kind": "device_cert"], kind: .deviceCert, signer: pk) }
        #expect(throws: Refusal.malformed) { try SignedObject.sign(["v": 2, "suite": 2, "kind": "revocation"], kind: .deviceCert, signer: pk) }
        // a signed object verifies only under the label of its kind
        let rev = try SignedObject.sign(["v": 2, "suite": 2, "kind": "revocation"], kind: .revocation, signer: pk)
        #expect(throws: Refusal.malformed) { try rev.verify(kind: .deviceCert, key: pk.publicKey) }
        #expect(SignedKind.allCases.count == Set(SignedKind.allCases.map(\.label)).count)
    }

    @Test func revocationVectors() throws {
        let cases = s2["revocations"].items
        #expect(cases.count == 4)
        for c in cases {
            let name = c["name"].str
            let identity = DeviceCertificate.Identity(deviceID: c["cert"]["device_id"].id, personID: c["cert"]["person_id"].id)
            do {
                let r = try Revocation.verify(c["signed"], personKey: c["pk_pub"].sigPub, cert: identity)
                #expect(!c["expect"]["ok"].isNull, "\(name) accepted")
                #expect(r.reason == c["expect"]["ok"]["reason"].str && r.deviceID.hex == c["expect"]["ok"]["device_id"].str, "\(name)")
            } catch let r as Refusal {
                #expect(r.rawValue == c["expect"]["refuse"].str, "\(name)")
            }
        }
        // field set, v, suite, kind and reason problems after a valid signature are malformed (section 6.2), not bad_signature
        let pk = try testSigner("person_alice.sig"), id = DeviceCertificate.Identity(deviceID: cases[0]["cert"]["device_id"].id, personID: cases[0]["cert"]["person_id"].id)
        func make(_ edit: (inout [String: JSONValue]) -> Void) throws -> JSONValue {
            var o = cases[0]["signed"]["o"].object!; edit(&o)
            return try SignedObject.sign(o, kind: .revocation, signer: pk).json
        }
        _ = try Revocation.verify(make { _ in }, personKey: pk.publicKey, cert: id)
        #expect(throws: Refusal.malformed) { try Revocation.verify(make { $0["extra"] = 1 }, personKey: pk.publicKey, cert: id) }
        #expect(throws: Refusal.malformed) { try Revocation.verify(make { $0["reason"] = "Lost" }, personKey: pk.publicKey, cert: id) }
        #expect(throws: Refusal.malformed) { try Revocation.verify(make { $0["revoked_ms"] = "1" }, personKey: pk.publicKey, cert: id) }
        #expect(throws: Refusal.malformed) { try Revocation.verify(make { $0["device_id"] = "not hex" }, personKey: pk.publicKey, cert: id) }
        #expect(throws: Refusal.malformed) { try Revocation.verify(make { $0["missing"] = nil; $0.removeValue(forKey: "reason") }, personKey: pk.publicKey, cert: id) }
        #expect(throws: Refusal.badSignature) { try Revocation.verify(make { _ in }, personKey: SoftwareSigner().publicKey, cert: id) }
        var badKind = cases[0]["signed"].object!
        badKind["sig"] = .string(B64U.encode(Data(count: 64)))
        #expect(throws: Refusal.badSignature) { try Revocation.verify(.object(badKind), personKey: cases[0]["pk_pub"].sigPub, cert: id) }
        #expect(throws: Refusal.otherPerson) {
            try Revocation.verify(cases[0]["signed"], personKey: cases[0]["pk_pub"].sigPub, cert: nil)
        }
    }

    @Test func questionHashVector() throws {
        let c = s2["question_hash"]
        #expect(B64U.encode(try Decisions.contentHash(of: c["content"])) == c["content_hash"].str)
        // content_hash binds every field
        var changed = c["content"].object!; changed["text"] = "Ship it!"
        #expect(try Decisions.contentHash(of: .object(changed)) != c["content_hash"].b64Data)
    }

    @Test func decisionVectors() throws {
        let d = s2["decisions"]
        let cases = d["cases"].items
        #expect(cases.count == 5)
        let valid = cases[0]
        let m = valid["meta"]
        #expect(try Decisions.signedBytes(workspace: valid["workspace_id"].id, questionID: m["question_id"].id, contentHash: m["content_hash"].b64Data,
                                          decisionID: m["decision_id"].id, answer: m["answer"]) == d["signed_bytes"].hexData)
        for c in cases {
            do {
                try Decisions.verifyOp(c["meta"], workspace: c["workspace_id"].id, deviceKey: c["dk_sig_pub"].sigPub)
                #expect(c["expect"]["ok"].bool == true, "\(c["name"].str)")
            } catch let r as Refusal {
                #expect(r.rawValue == c["expect"]["refuse"].str, "\(c["name"].str)")
            }
        }
    }

    @Test func decisionSignedByDeviceVerifies() throws {
        let dk = try testSigner("phone.sig"), ws = s2["ids"]["workspace_a"].id
        let qh = s2["question_hash"]["content_hash"].b64Data
        let op = try Decisions.makeOp(workspace: ws, questionID: ID16.random(), contentHash: qh, decisionID: ID16.random(),
                                      answer: ["choice": "yes", "n": 2], signer: dk)
        try Decisions.verifyOp(op, workspace: ws, deviceKey: dk.publicKey)
        #expect(throws: Refusal.badSignature) { try Decisions.verifyOp(op, workspace: ID16.random(), deviceKey: dk.publicKey) }
        var extra = op.object!; extra["x"] = 1
        #expect(throws: Refusal.malformed) { try Decisions.verifyOp(.object(extra), workspace: ws, deviceKey: dk.publicKey) }
        var badHash = op.object!; badHash["content_hash"] = .string(B64U.encode(Data(count: 31)))
        #expect(throws: Refusal.malformed) { try Decisions.verifyOp(.object(badHash), workspace: ws, deviceKey: dk.publicKey) }
    }

    @Test func personTextCleaning() {
        #expect(PersonText.clean("abc\u{0}\u{7}\u{200B}\u{202E}\u{2028}\u{2029}\u{E000}\u{FEFF}\u{AD}def\r\nghi") == "abcdef\nghi")
        #expect(PersonText.clean("a\u{378}b") == "ab")                                    // unassigned (Cn)
        #expect(PersonText.clean(String(repeating: "x", count: 200)).unicodeScalars.count == 80)
        #expect(PersonText.clean("e\u{301}") == "e\u{301}")                                // no normalisation
        #expect(PersonText.clean("\u{1F600}") == "\u{1F600}")
        // controls are removed before truncating, so they do not eat the 80-code-point budget
        #expect(PersonText.clean(String(repeating: "\u{200B}", count: 100) + String(repeating: "y", count: 100)).unicodeScalars.count == 80)
        // the vector's expected label: "abc" + 77 x
        let expected = "abc" + String(repeating: "x", count: 77)
        #expect(PersonText.clean("a\u{0}b\u{202E}c" + String(repeating: "x", count: 200)) == expected)
    }

    /// Every suite-2 group is either run by a test in this target or listed as deferred above: this fails when the vector
    /// file gains a group, and pins the case counts the gates assert.
    @Test func everyGroupIsAccountedFor() {
        let run: Set<String> = ["keys", "ids", "sign", "hkdf", "salted_aead", "seal", "seal_open", "label_sealed", "certs", "revocations",
                                "card", "wk_grants", "wk_commit", "member_lists", "cert_request", "question_hash", "decisions", "push", "relay_auth", "drop",
                                "cert_binding", "rejected_forms", "approved_anchor"]      // G3b: OrchProtocolTests, OrchFakeHostTests, OrchRelayFixtureTests
        let partial: Set<String> = ["bridge"]                       // seal, device_cases and sas run; host_cases, pair_answers, links deferred
        // member_list_snapshots run through WorkspaceSession in OrchFakeHostTests.SnapshotVectorTests; checkpoints are F1 (host/relay)
        let deferred: Set<String> = ["enroll", "webauthn", "revocation_op", "ws_envelopes", "publish", "p3", "member_list_snapshots", "checkpoints"]  // p3: relay state machine; its membership cases replay in OrchRelayFixtureTests.P3MembershipVectorTests, the rest with PR4/PR5
        let meta: Set<String> = ["suite", "name"]
        let all = Set(s2.object!.keys)
        #expect(all == run.union(partial).union(deferred).union(meta), "unaccounted: \(all.subtracting(run).subtracting(partial).subtracting(deferred).subtracting(meta))")
        let b = s2["bridge"].object!
        #expect(b["seal"]?.array?.count == 1 && b["device_cases"]?.array?.count == 11 && b["host_cases"]?.array?.count == 47
                && b["pair_answers"]?.array?.count == 20 && b["links"]?.array?.count == 6)
        #expect(s2["card"]["cases"].items.count == 19 && s2["card"]["hosted_marker"].items.count == 4 && s2["member_lists"].items.count == 34
                && s2["wk_grants"]["cases"].items.count == 3 && s2["cert_request"]["cases"].items.count == 10
                && s2["cert_request"]["open_cases"].items.count == 5 && s2["relay_auth"]["cases"].items.count == 6)
        let d = s2["drop"]
        #expect(d["descriptor_cases"].items.count == 5 && d["claims"].items.count == 6 && d["documents"].items.count == 7
                && d["document_chains"].items.count == 3 && d["wrap_negative"].items.count == 3 && d["wraps"].object?.count == 5)
    }
}
