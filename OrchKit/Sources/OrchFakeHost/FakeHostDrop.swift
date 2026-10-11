import CryptoKit
import Foundation
import OrchClient
import OrchProtocol

extension FakeHost {
    func handleDropRewrap(_ request: HostRequest) async -> HostReply {
        guard let o = request.meta.object, Set(o.keys) == ["op", "object_id", "version"], request.data.isEmpty,
              let object = o["object_id"]?.string.flatMap(ID16.init(hex:)), let n = o["version"]?.int, n > 0, n <= UInt32.max,
              request.scopes.contains(o["op"] == "drop_claim" ? "operate" : "look"), let ctx = bridgeRelay else { return .refuse(.malformed) }
        do {
            if o["op"] == "drop_claim" {
                _ = try HostAPI.expect(await claimDrop(object: object, version: UInt32(n), relay: ctx.relay, session: ctx.session))
            } else {
                try await rewrapDrop(object: object, version: UInt32(n), relay: ctx.relay, session: ctx.session)
            }
            return .response(status: 200, headers: [:], data: HostAPI.json())
        } catch { return .refuse(.forbiddenScope) }
    }

    public func rewrapDrop(object: ID16, version: UInt32, relay: FakeRelay, session: RelaySession) async throws {
        try capability.generation.check()
        guard !rotationRequired, let current = wks[epoch] else { throw DropError.unauthorized }
        let startEpoch = epoch
        let (descriptor, wraps) = try await relay.rewrapSource(object: object, version: version, workspace: workspace, token: session.token)
        guard epoch == startEpoch, !rotationRequired else { throw Refusal.badEpoch }
        let dek = openDropKey(wraps, descriptor: descriptor)
        guard let dek, DropKeys.dekCommit(object: object, version: version, dek: dek) == descriptor.dekCommit else { throw DropError.integrity }
        let wrap = try DropWrap.wrapWithSecret(kind: .wk, secret: current, target: workspace, keyVersion: epoch, object: object, version: version, dek: dek)
        // The descriptor remains inbox after claim; relay claim state is authoritative.
        try await relay.putRewrap(wrap, token: session.token)
    }

    /// Claim signatures and DEKs stay on the host. The relay serializes competing claims.
    public func claimDrop(object: ID16, version: UInt32, relay: FakeRelay, session: RelaySession) async throws -> WireReply {
        try capability.generation.check()
        guard !rotationRequired, let wk = wks[epoch] else { throw DropError.unauthorized }
        let startEpoch = epoch
        let (d, wraps) = try await relay.rewrapSource(object: object, version: version, workspace: workspace, token: session.token)
        guard epoch == startEpoch, !rotationRequired else { throw Refusal.badEpoch }
        let opened = openDropKey(wraps, descriptor: d)
        guard let dek = opened, DropKeys.dekCommit(object: object, version: version, dek: dek) == d.dekCommit else { throw DropError.integrity }
        let record = try DropWrap.wrapWithSecret(kind: .wk, secret: wk, target: workspace, keyVersion: epoch, object: object, version: version, dek: dek)
        let claim = try DropClaim.make(wsk: wsk, object: object, workspace: workspace, wrap: record)
        return try await relay.send(WireRequest(method: "POST", target: "/drop/\(object.hex)/claim",
            headers: [HostAPI.versionHeader: "0", "authorization": "Bearer \(session.token)"], body: canonicalJSON(claim.json), clientAddress: "fake-host"))
    }

    private func openDropKey(_ wraps: [DropWrapRecord], descriptor: DropDescriptor) -> SymmetricKey? {
        for wrap in wraps where wrap.target == workspace {
            let key: SymmetricKey?
            if wrap.targetKind == .wk, let old = wks[wrap.keyVersion] { key = try? DropWrap.unwrap(wrap, with: .wk(old)) }
            else if wrap.targetKind == .wxk, wrap.keyVersion == 1 { key = try? DropWrap.unwrap(wrap, agreement: wxk) }
            else { continue }
            if let key, DropKeys.dekCommit(object: descriptor.object, version: descriptor.version, dek: key) == descriptor.dekCommit { return key }
        }
        return nil
    }

    /// Real §10 fixtures, uploaded through the same protocol route as phone files.
    public func seedDrop(relay: FakeRelay, transport: any RelayTransport, session: RelaySession) async throws {
        guard let wk = wks[epoch], !rotationRequired else { throw DropError.unauthorized }
        if dropSeedBodies == nil {
            let fixtures = isClientHosted
                ? [("deployment.txt", "text/plain", "Demo deployment ready."), ("Runbook", "text/plain", "Runbook v1"), ("Runbook", "text/plain", "Runbook v2")]
                : [("readme.txt", "text/plain", "Welcome to orch.\n"), ("empty.txt", "text/plain", ""),
                   ("note.txt", "text/plain", "A short UTF-8 note: Grüezi."), ("link.txt", "text/uri-list", "https://example.invalid/")]
            var bodies: [Data] = []
            var parent: DropDescriptor?
            for (i, fixture) in fixtures.enumerated() {
                let (name, mime, text) = fixture
                let id = parent?.object ?? entropy.id16(), data = Data(text.utf8)
                var body = try DropUpload.seal(data, metadata: DropMetadata(name: name, mime: mime, size: Int64(data.count), transcript: nil),
                    object: id, workspace: workspace, author: workspace, authorKind: "workspace", signer: wsk,
                    wxk: wxk.publicKey, wxkVersion: 1, sender: nil, wk: wk, epoch: epoch, now: wall.nowMs,
                    expiry: DropUpload.addMs(wall.nowMs, 604800000), parent: parent, kind: isClientHosted && i > 0 ? "document" : "file")
                if isClientHosted, i == 0 {
                    var o = try StrictJSON.parse(body, maxBytes: 36 << 20).object!
                    var raw = o["descriptor"]!.object!["o"]!.object!
                    raw["recipients"] = "inbox"
                    o["descriptor"] = try SignedObject.sign(raw, kind: .dropObject, signer: wsk).json
                    o["wraps"] = .array(o["wraps"]!.array!.filter { $0.object?["target_kind"] == "wxk" })
                    body = try canonicalJSON(.object(o))
                }
                bodies.append(body)
                if isClientHosted, i == 1 {
                    parent = try DropDescriptor(object: StrictJSON.parse(body, maxBytes: 36 << 20).object!["descriptor"]!.object!["o"]!.object!)
                }
            }
            dropSeedBodies = bodies
        }
        for body in dropSeedBodies!.dropFirst(dropSeedUploaded) {
            let o = try StrictJSON.parse(body, maxBytes: 36 << 20).object!
            let descriptor = try DropDescriptor(object: o["descriptor"]!.object!["o"]!.object!)
            let reply = try await transport.dropPut(objectID: descriptor.object, ifMatch: descriptor.parent, body: body, session: session)
            if reply.status == 409 {
                let committed = try await transport.dropGet(objectID: descriptor.object, version: descriptor.version, part: .descriptor, session: session)
                let got = try StrictJSON.parse(HostAPI.expect(committed), maxBytes: 128 << 10).object?["descriptor"]
                guard let got, try canonicalJSON(got) == canonicalJSON(o["descriptor"]!) else { throw DropError.conflict }
            } else { _ = try HostAPI.expect(reply, status: 201) }
            dropSeedUploaded += 1
        }
        if isClientHosted, let body = dropSeedBodies?.first {
            let d = try DropDescriptor(object: StrictJSON.parse(body, maxBytes: 36 << 20).object!["descriptor"]!.object!["o"]!.object!)
            _ = try HostAPI.expect(await claimDrop(object: d.object, version: d.version, relay: relay, session: session))
        }
    }
}

public extension FakeHost {
    /// An unclaimed inbox item for the bounded Demo claim UI test.
    func demoInboxDrop(relay: FakeRelay, transport: any RelayTransport, session: RelaySession) async throws {
        try capability.generation.check()
        guard let wk = wks[epoch] else { throw DropError.unavailableKey }
        let object = entropy.id16(), data = Data("Claimed Demo bytes".utf8)
        let sealed = try DropUpload.seal(data, metadata: DropMetadata(name: "claim.txt", mime: "text/plain", size: Int64(data.count), transcript: nil),
            object: object, workspace: workspace, author: workspace, authorKind: "workspace", signer: wsk,
            wxk: wxk.publicKey, wxkVersion: 1, sender: nil, wk: wk, epoch: epoch, now: wall.nowMs,
            expiry: DropUpload.addMs(wall.nowMs, 604800000))
        var body = try StrictJSON.parse(sealed).object!
        var descriptor = body["descriptor"]!.object!["o"]!.object!
        descriptor["recipients"] = "inbox"
        body["descriptor"] = try SignedObject.sign(descriptor, kind: .dropObject, signer: wsk).json
        body["wraps"] = .array(body["wraps"]!.array!.filter { $0.object?["target_kind"] == "wxk" })
        _ = try HostAPI.expect(await transport.dropPut(objectID: object, ifMatch: 0, body: canonicalJSON(.object(body)), session: session), status: 201)
    }
}
