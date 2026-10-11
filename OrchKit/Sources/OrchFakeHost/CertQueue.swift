import Foundation
import OrchClient
import OrchProtocol

/// The relay's `cert_pending` queue (protocol-v2 P3-D11, section 19.3): one transactional state machine per request,
/// `open -> challenged -> signed`, `rejected` from open or challenged, `expired` from either at `expires_ms`. Pure and
/// value-typed so the FakeRelay and the vector tests (`p3` ops `request` and `queue`) run the same code.
///
/// Every object is verified before it changes anything: the request under the card's `WSK`, challenges, rejections and
/// certificates under the account `PK`. A valid signature over an identical canonical object (`cj(o)`) is idempotent
/// (200, no state change), whatever its signature bytes (G0a review 3).
package enum CertQueue {
    package enum State: String, Sendable, Equatable { case open, challenged, signed, rejected, expired }

    package struct Record: Sendable, Equatable {
        package var request: JSONValue
        package let requestID: ID16
        package let workspace: ID16
        package let person: ID16
        package let primary: ID16
        package let expiresMs: Int64
        package var state: State
        package var challenge: JSONValue?
        package var cert: JSONValue?
        package var rejection: JSONValue?

        package var object: [String: JSONValue] { request.object?["o"]?.object ?? [:] }
        /// Open for quota and for the one-open-request-per-workspace rule: open or challenged, and unexpired.
        package func isOpen(at now: Int64) -> Bool { (state == .open || state == .challenged) && now < expiresMs }
        /// Terminal records (and expired ones) stay readable until `expires_ms + 60 s`.
        package func isRetained(at now: Int64) -> Bool { now < saturatingAdd(expiresMs, CertQueue.retentionMs) }

        package init(request: JSONValue, requestID: ID16, workspace: ID16, person: ID16, primary: ID16, expiresMs: Int64, state: State,
                     challenge: JSONValue? = nil, cert: JSONValue? = nil, rejection: JSONValue? = nil) {
            self.request = request; self.requestID = requestID; self.workspace = workspace; self.person = person; self.primary = primary
            self.expiresMs = expiresMs; self.state = state; self.challenge = challenge; self.cert = cert; self.rejection = rejection
        }
    }

    package enum Outcome: Equatable, Sendable {
        /// Accepted: the request id (admission) or the record's state after the step (`unmatched` for a certificate that does
        /// not complete the request).
        case ok(String)
        case refuse(RelayRefusal.Code)
    }

    package static let retentionMs: Int64 = 60_000
    package static let maxOpenPerPerson = 64
    static let requestFields: Set<String> = ["v", "suite", "kind", "request_id", "workspace_id", "person_id", "primary_device_id",
                                             "created_ms", "expires_ms", "sealed"]
    static let challengeFields: Set<String> = ["v", "suite", "kind", "request_id", "workspace_id", "person_id", "device_id", "dk_sig_pub",
                                               "dk_kx_pub", "primary_nonce", "expires_ms"]

    /// Expires a non-terminal record whose time has come (the transition happens on the first touch at or after `expires_ms`).
    static func age(_ r: inout Record, now: Int64) {
        if (r.state == .open || r.state == .challenged), now >= r.expiresMs { r.state = .expired }
    }

    // MARK: step 1, the host's request (W(g), card owner = person)

    /// Section 19.6 order: signature under `WSK`, shape, then context (`other_person`, `other_workspace`,
    /// `not_for_this_device`), the time window (`expired`), the id's binding (identical canonical object -> its id again;
    /// other content -> `replayed`), then the open-request rules (`request_open` per workspace, `quota_exceeded` at 64 per
    /// person). `isAddressee` says whether `primary_device_id` is a current device of `owner`.
    package static func admit(_ signed: JSONValue, wsk: SigningPublicKey, workspace: ID16, owner: ID16, isAddressee: (ID16) -> Bool,
                              records: inout [ID16: Record], nowMs now: Int64) -> Outcome {
        let o: [String: JSONValue]
        do { o = try SignedObject.parse(signed).verify(kind: .certRequest, key: wsk) }
        catch Refusal.badSignature { return .refuse(.badSignature) } catch { return .refuse(.malformed) }
        guard o.keys.count == requestFields.count, Set(o.keys) == requestFields, o.allSatisfyASCIIKeys,
              let rid = o["request_id"]?.string.flatMap(ID16.init(hex:)), let ws = o["workspace_id"]?.string.flatMap(ID16.init(hex:)),
              let person = o["person_id"]?.string.flatMap(ID16.init(hex:)), let primary = o["primary_device_id"]?.string.flatMap(ID16.init(hex:)),
              let created = o["created_ms"]?.int, let expires = o["expires_ms"]?.int,
              let sealed = o["sealed"]?.string.flatMap({ B64U.decode($0) }), !sealed.isEmpty, sealed.count <= CertRequest.maxSealedBytes
        else { return .refuse(.malformed) }
        guard person == owner else { return .refuse(.otherPerson) }
        guard ws == workspace else { return .refuse(.otherWorkspace) }
        guard isAddressee(primary) else { return .refuse(.notForThisDevice) }
        let life = expires.subtractingReportingOverflow(created)
        guard !life.overflow, life.partialValue > 0, life.partialValue <= CertRequest.lifetimeMs,
              saturatingAdd(created, -Suite2.skewMs) <= now, now < expires else { return .refuse(.expired) }
        if let existing = records[rid] {
            return SignedObject.sameCanonicalObject(existing.request, signed) ? .ok(rid.hex) : .refuse(.replayed)
        }
        for k in Array(records.keys) { age(&records[k]!, now: now) }
        if records.values.contains(where: { $0.workspace == ws && $0.isOpen(at: now) }) { return .refuse(.requestOpen) }
        if records.values.filter({ $0.person == person && $0.isOpen(at: now) }).count >= maxOpenPerPerson { return .refuse(.quotaExceeded) }
        records[rid] = Record(request: signed, requestID: rid, workspace: ws, person: person, primary: primary, expiresMs: expires, state: .open)
        return .ok(rid.hex)
    }

    // MARK: step 3, the primary's challenge (D(p), addressee)

    package static func challenge(_ r: inout Record, signed: JSONValue, pk: SigningPublicKey, nowMs now: Int64) -> Outcome {
        guard r.isRetained(at: now) else { return .refuse(.notFound) }
        let o: [String: JSONValue]
        do { o = try SignedObject.parse(signed).verify(kind: .certChallenge, key: pk) }
        catch Refusal.badSignature { return .refuse(.badSignature) } catch { return .refuse(.malformed) }
        guard Set(o.keys) == challengeFields, o.keys.count == challengeFields.count, o.allSatisfyASCIIKeys else { return .refuse(.malformed) }
        guard o["person_id"]?.string.flatMap(ID16.init(hex:)) == r.person, r.person == Identifiers.personID(pk) else { return .refuse(.otherPerson) }
        guard o["workspace_id"]?.string.flatMap(ID16.init(hex:)) == r.workspace else { return .refuse(.otherWorkspace) }
        guard o["request_id"]?.string.flatMap(ID16.init(hex:)) == r.requestID else { return .refuse(.notForThisDevice) }
        // valid device keys and the derived device id, the request's own expiry, a 32-byte nonce (section 19.6: malformed)
        guard let sig = o["dk_sig_pub"]?.string.flatMap({ B64U.decode($0, length: Suite2.publicKeyLength) }).flatMap({ try? SigningPublicKey(x963: $0) }),
              o["dk_kx_pub"]?.string.flatMap({ B64U.decode($0, length: Suite2.publicKeyLength) }).flatMap({ try? AgreementPublicKey(x963: $0) }) != nil,
              o["device_id"]?.string.flatMap(ID16.init(hex:)) == Identifiers.deviceID(sig),
              o["primary_nonce"]?.string.flatMap({ B64U.decode($0, length: 32) }) != nil,
              o["expires_ms"]?.int == r.expiresMs else { return .refuse(.malformed) }
        age(&r, now: now)
        if r.state == .expired { return .refuse(.expired) }
        if let stored = r.challenge, SignedObject.sameCanonicalObject(stored, signed) { return .ok(r.state.rawValue) }
        switch r.state {
        case .signed: return .refuse(.alreadySigned)
        case .rejected, .challenged: return .refuse(.replayed)        // no replacement, and nothing after a rejection
        case .open:
            r.challenge = signed; r.state = .challenged
            return .ok(State.challenged.rawValue)
        case .expired: return .refuse(.expired)
        }
    }

    // MARK: the primary's rejection (D(p), addressee)

    package static func reject(_ r: inout Record, signed: JSONValue, pk: SigningPublicKey, nowMs now: Int64) -> Outcome {
        guard r.isRetained(at: now) else { return .refuse(.notFound) }
        do { _ = try CertRejection.check(signed, pk: pk, request: r.object) }
        catch let e as Refusal { return .refuse(RelayRefusal.Code(rawValue: e.rawValue) ?? .malformed) }
        catch { return .refuse(.malformed) }
        age(&r, now: now)
        switch r.state {
        case .expired: return .refuse(.expired)
        case .signed: return .refuse(.alreadySigned)
        case .rejected:
            // the record binds every rejection field, so a verified rejection here is the identical canonical object
            guard let stored = r.rejection, SignedObject.sameCanonicalObject(stored, signed) else { return .refuse(.replayed) }
            return .ok(State.rejected.rawValue)
        case .open, .challenged:
            r.rejection = signed; r.state = .rejected
            return .ok(State.rejected.rawValue)
        }
    }

    // MARK: completion by a stored certificate (PUT devices)

    /// A certificate completes the request only when it verifies under `PK` and names both keys, the device and the person of
    /// the stored challenge; any other valid certificate is `unmatched` and changes nothing.
    package static func certificate(_ r: inout Record, signed: JSONValue, pk: SigningPublicKey, nowMs now: Int64) -> Outcome {
        guard r.isRetained(at: now) else { return .refuse(.notFound) }
        do { _ = try SignedObject.parse(signed).verify(kind: .deviceCert, key: pk) }
        catch Refusal.badSignature { return .refuse(.badSignature) } catch { return .refuse(.certInvalid) }
        let c: DeviceCertificate
        do { c = try DeviceCertificate.verify(signed, personKey: pk, nowMs: now) }
        catch let e as Refusal { return .refuse(RelayRefusal.Code(rawValue: e.rawValue) ?? .certInvalid) }
        catch { return .refuse(.certInvalid) }
        age(&r, now: now)
        switch r.state {
        case .expired: return .refuse(.expired)
        case .rejected: return .refuse(.replayed)
        case .signed:
            if let stored = r.cert, SignedObject.sameCanonicalObject(stored, signed) { return .ok(State.signed.rawValue) }
            return .ok("unmatched")
        case .open: return .ok("unmatched")
        case .challenged:
            guard let ch = r.challenge?.object?["o"]?.object,
                  ch["dk_sig_pub"]?.string.flatMap({ B64U.decode($0) }) == c.signingKey.x963,
                  ch["dk_kx_pub"]?.string.flatMap({ B64U.decode($0) }) == c.agreementKey.x963,
                  ch["device_id"]?.string.flatMap(ID16.init(hex:)) == c.deviceID, c.personID == r.person else { return .ok("unmatched") }
            r.cert = signed; r.state = .signed
            return .ok(State.signed.rawValue)
        }
    }

    /// `GET /v2/cert-requests/{id}`: always the four fields, null when absent.
    package static func view(_ r: Record, nowMs now: Int64) -> [String: JSONValue] {
        var r = r
        age(&r, now: now)
        return ["state": .string(r.state.rawValue), "challenge": r.challenge ?? .null, "cert": r.cert ?? .null, "rejection": r.rejection ?? .null]
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    fileprivate var allSatisfyASCIIKeys: Bool { keys.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { $0 < 0x80 } } }
}
