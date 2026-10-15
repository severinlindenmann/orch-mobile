import CryptoKit
import Foundation
import OrchClient
import OrchProtocol

/// The Drop routes of the fake relay, aligned to orch-relay's design (P3-D39, protocol-v2 section 19.9, amendment A1): everything under
/// `/v2`, the streamed `ODU2` upload frame, exact retry (200), a tombstone check before the CAS, current-epoch `wk` wraps, per-caller
/// wrap filtering, change-position list pages with `state` and tombstones, descriptor pages, a host-only retire, wrap re-writes with
/// `wrap_conflict`, 410 for expired and retired objects (404 once the tombstone ends) and the quotas with their `quota` names. Limits
/// that need time or concurrency in the real relay (slots, rate buckets) are knobs of `RelayLimits` that default to off.
extension FakeRelay {
    static let dropTombstoneMs: Int64 = 30 * 86_400_000
    static let dropWindowMs: Int64 = 604_800_000 + 300_000
    static let dropMinLifeMs: Int64 = 60_000
    static let dropListPageBytes = 2 << 20

    // MARK: visibility

    func dropAllowed(_ s: Session, workspace ws: ID16, write: Bool) -> Bool {
        if s.kind == .workspace { return s.id == ws }
        guard memberGate(s, ws: ws) == nil, let card = workspaces[ws]?.card, deviceUsable(s.id, card: card),
              let scopes = workspaces[ws]?.members[s.id]?.scopeStrings else { return false }
        return scopes.contains(write ? "operate" : "look")
    }

    /// The workspace an object currently belongs to: its space, or the claimer for a claimed `inbox` object.
    func dropWorkspace(_ id: ID16) -> ID16? { drops[id]?.last.map { claims[id] ?? $0.parsed.space } }

    /// A caller sees an object when it is a member with `look` of its workspace and the newest version's `recipients` does not exclude
    /// it. Unclaimed `inbox` objects are visible (no wrap a device can open exists before the claim).
    func dropVisible(_ id: ID16, _ s: Session) -> Bool {
        guard let versions = drops[id], let v = versions.last, let ws = dropWorkspace(id), dropAllowed(s, workspace: ws, write: false) else { return false }
        if s.kind == .workspace || claims[id] != nil { return true }
        switch v.parsed.recipients {
        case .inbox: return versions.contains { $0.wraps.contains { $0.target == v.parsed.space && $0.targetKind == .wxk } }
        case .ids(let ids): return ids.contains(v.parsed.space) || ids.contains(s.id) || v.parsed.authorID == s.id
        }
    }

    /// Only the caller's usable wraps: a W session its workspace's `wk` and `wxk` wraps, a device its workspace's `wk` wraps and its own
    /// `device` wraps (never `wxk`).
    func dropWraps(_ v: DropVersion, object id: ID16, for s: Session) -> [DropWrapRecord] {
        let ws = dropWorkspace(id) ?? v.parsed.space
        return v.wraps.filter { w in
            switch s.kind {
            case .workspace: w.target == s.id && (w.targetKind == .wk || w.targetKind == .wxk)
            case .device: (w.targetKind == .wk && w.target == ws) || (w.targetKind == .device && w.target == s.id)
            }
        }
    }

    /// `retired`, or a file at or past `expires_ms`; both stay readable as 410 for 30 days.
    func dropTombstone(_ id: ID16) -> (state: String, untilMs: Int64)? {
        guard let head = drops[id]?.last else { return nil }
        if let at = dropRetiredMs[id] { return ("retired", at + Self.dropTombstoneMs) }
        if head.parsed.objectKind == "file", let e = head.parsed.expiresMs, e <= wall.nowMs { return ("expired", e + Self.dropTombstoneMs) }
        return nil
    }

    private func touchDrop(_ id: ID16, workspace ws: ID16) {
        let n = (dropCounters[ws] ?? 0) + 1
        dropCounters[ws] = n; dropN[id] = n
    }

    /// Drops the objects whose tombstone ended (they leave without a new `n`; every read is 404 again).
    private func sweepDrops() {
        let ended = drops.keys.filter { dropTombstone($0).map { $0.untilMs <= wall.nowMs } ?? false }
        for id in ended { drops[id] = nil; claims[id] = nil; dropN[id] = nil; dropRetiredMs[id] = nil }
    }

    /// An expiry reaches `n` only with the sweep; the fake lets the first request after the expiry take the new position.
    private func settleExpiries() {
        for (id, versions) in drops {
            guard let head = versions.last, let e = head.parsed.expiresMs, head.parsed.objectKind == "file", e <= wall.nowMs, dropRetiredMs[id] == nil else { continue }
            if dropExpirySettled.insert(id).inserted { touchDrop(id, workspace: head.parsed.space) }
        }
    }

    /// Deterministic Demo control; applies only to the next encrypted Drop PUT.
    public func demoRejectNextDrop() throws {
        try checkLive()
        demoDropRejections += 1
    }

    /// Tests: the next Drop `PUT` is answered with this reply, once, and nothing is stored (the early-answer case).
    package func scriptNextDropPut(_ reply: WireReply) { dropScript.append(reply) }

    // MARK: routing

    func dropRoute(_ r: WireRequest, _ path: [String], _ query: String?) throws -> WireReply {
        if r.method == "PUT", path.count == 3, path[2] == "versions" {
            if demoDropRejections > 0 {
                demoDropRejections -= 1
                return refuse(403, .notEligible)      // the Demo control "reject next upload": a refusal in section 14 form
            }
            if !dropScript.isEmpty { return dropScript.removeFirst() }
        }
        guard let session = authenticate(r) else { return refuse(401, .unauthenticated) }
        sweepDrops(); settleExpiries()
        switch (r.method, path.count) {
        case ("POST", 2) where path[1] == "list": return dropList(r, query, session)
        case ("GET", 3) where path[2] == "descriptors": return dropDescriptors(path[1], query, session)
        case ("PUT", 3) where path[2] == "versions": return dropPut(r, path[1], query, session)
        case ("GET", 5) where path[2] == "versions": return try dropRead(path[1], path[3], path[4], query, session)
        case ("PUT", 5) where path[2] == "versions" && path[4] == "wraps": return dropPutWraps(r, path[1], path[3], query, session)
        case ("POST", 3) where path[2] == "claim": return dropClaim(r, path[1], query, session)
        case ("POST", 3) where path[2] == "retire": return dropRetire(r, path[1], query, session)
        default: return refuse(404, .notFound)
        }
    }

    private func ok(_ status: Int, _ fields: [String: JSONValue], etag version: UInt32? = nil, headers: [String: String] = [:]) -> WireReply {
        var h = headers
        if let v = version { h["etag"] = "\"\(v)\"" }
        return json(status, fields, headers: h)
    }

    // MARK: list and descriptors (reads)

    private func dropList(_ r: WireRequest, _ query: String?, _ session: Session) -> WireReply {
        guard query == nil else { return refuse(400, .malformed) }
        guard r.body.count <= 16 << 10, let o = try? StrictJSON.parse(r.body, maxBytes: 16 << 10).object,
              Set(o.keys).isSubset(of: ["workspace_id", "direction", "after", "limit"]), Set(["workspace_id", "direction"]).isSubset(of: Set(o.keys)),
              let ws = o["workspace_id"]?.string.flatMap(ID16.init(hex:)),
              let direction = o["direction"]?.string, ["received", "sending"].contains(direction) else { return refuse(400, .malformed) }
        var after: UInt64 = 0, limit = min(64, limits.dropListPageSize)
        if let a = o["after"] { guard let n = a.int, n >= 0 else { return refuse(400, .malformed) }; after = UInt64(n) }
        if let l = o["limit"] { guard let n = l.int, (1...64).contains(n) else { return refuse(400, .malformed) }; limit = min(Int(n), limit) }
        guard dropAllowed(session, workspace: ws, write: false) else { return refuse(403, .notEligible) }
        let rows = drops.keys.compactMap { id -> (n: UInt64, id: ID16)? in
            guard let head = drops[id]?.last, dropWorkspace(id) == ws, dropVisible(id, session), let n = dropN[id], n > after,
                  (direction == "sending") == (head.parsed.authorID == session.id) else { return nil }
            return (n, id)
        }.sorted { $0.n < $1.n }
        var entries: [JSONValue] = [], bytes = 0, last: UInt64 = 0
        for row in rows {
            if entries.count >= limit { break }
            let entry = dropEntry(row.id, n: row.n, session)
            let size = (try? canonicalJSON(entry).count) ?? 0
            if !entries.isEmpty, bytes + size > Self.dropListPageBytes { break }
            entries.append(entry); bytes += size; last = row.n
        }
        let more = rows.contains { $0.n > last } && !entries.isEmpty
        return json(200, ["objects": .array(entries), "next": more ? .int(Int64(last)) : .null])
    }

    private func dropEntry(_ id: ID16, n: UInt64, _ session: Session) -> JSONValue {
        let v = drops[id]!.last!
        let tomb = dropTombstone(id)
        return .object([
            "n": .int(Int64(n)), "object_id": .string(id.hex), "version": .int(Int64(v.parsed.version)),
            "state": .string(tomb?.state ?? "live"), "tombstone_until_ms": tomb.map { .int($0.untilMs) } ?? .null,
            "descriptor": tomb == nil ? v.descriptor : .null,
            "wraps": .array(tomb == nil ? dropWraps(v, object: id, for: session).map(\.json) : []),
            "claimed_by": claims[id].map { .string($0.hex) } ?? .null])
    }

    private func dropDescriptors(_ idText: String, _ query: String?, _ session: Session) -> WireReply {
        guard let id = ID16(hex: idText), let q = queryItems(query, allowed: ["after", "limit"]) else { return refuse(400, .malformed) }
        var after = 0, limit = 256
        if let a = q["after"] { guard let n = HostAPI.parseDecimal(a), n <= UInt64(UInt32.max) else { return refuse(400, .malformed) }; after = Int(n) }
        if let l = q["limit"] { guard let n = HostAPI.parseDecimal(l), (1...256).contains(n) else { return refuse(400, .malformed) }; limit = Int(n) }
        guard let versions = drops[id] else { return refuse(404, .notFound) }
        guard dropVisible(id, session) else { return refuse(403, .notEligible) }
        if dropTombstone(id) != nil { return refuse(410, .expired) }
        var out: [JSONValue] = [], bytes = 0
        for v in versions where Int(v.parsed.version) > after {
            let size = (try? canonicalJSON(v.descriptor).count) ?? 0
            if out.count >= limit || (!out.isEmpty && bytes + size > 1 << 20) { break }
            out.append(v.descriptor); bytes += size
        }
        let lastVersion = after + out.count
        return json(200, ["descriptors": .array(out), "next": lastVersion < versions.count && !out.isEmpty ? .int(Int64(lastVersion)) : .null])
    }

    /// Reads answer in this order: object absent 404; not visible 403 (tombstones too); expired, retired or pruned 410; version absent 404.
    private func dropRead(_ idText: String, _ versionText: String, _ part: String, _ query: String?, _ session: Session) throws -> WireReply {
        guard query == nil, let id = ID16(hex: idText), let n = HostAPI.parseDecimal(versionText), n > 0 else { return refuse(400, .malformed) }
        guard let versions = drops[id] else { return refuse(404, .notFound) }
        guard dropVisible(id, session) else { return refuse(403, .notEligible) }
        if dropTombstone(id) != nil { return refuse(410, .expired) }
        guard n <= UInt64(versions.count) else { return refuse(404, .notFound) }
        let v = versions[Int(n) - 1]
        switch part {
        case "descriptor": return ok(200, ["descriptor": v.descriptor], etag: v.parsed.version)
        case "wraps": return ok(200, ["wraps": .array(dropWraps(v, object: id, for: session).map(\.json)), "claimed_by": claims[id].map { .string($0.hex) } ?? .null])
        case "blob":
            if v.parsed.recipients == .inbox, claims[id] == nil { return refuse(403, .notEligible) }
            if dropPruned(versions, index: Int(n) - 1) { return refuse(410, .expired) }
            return try WireReply(status: 200, headers: ["etag": "\"\(v.parsed.version)\"", "cache-control": "no-store"], body: v.blob)
        default: return refuse(404, .notFound)
        }
    }

    /// A superseded document blob is kept while among the newest 8 versions or younger than 30 days (since it was superseded).
    private func dropPruned(_ versions: [DropVersion], index i: Int) -> Bool {
        guard versions.last?.parsed.objectKind == "document", i < versions.count - 8 else { return false }
        return wall.nowMs - versions[i + 1].parsed.createdMs >= Self.dropTombstoneMs
    }

    // MARK: PUT

    /// The request body as bytes (a file body is read whole: the fake is in-process).
    func dropBodyBytes(_ r: WireRequest) -> Data? { r.body }

    private func dropPut(_ r: WireRequest, _ idText: String, _ query: String?, _ session: Session) -> WireReply {
        guard query == nil, let id = ID16(hex: idText) else { return refuse(400, .malformed) }
        // If-Match: the decimal, or the same decimal quoted (anything else is 428).
        var ifMatch = r.header("if-match")
        if let m = ifMatch, m.count >= 3, m.hasPrefix("\""), m.hasSuffix("\"") { ifMatch = String(m.dropFirst().dropLast()) }
        guard DropDocument.isValidIfMatch(ifMatch) else { return refuse(428, .preconditionRequired) }
        guard r.header("content-type") == "application/octet-stream" else { return refuse(400, .malformed) }
        guard let body = dropBodyBytes(r), body.count >= DropFrame.prefixLength else { return refuse(400, .malformed) }
        let parts: DropFrame.Parts
        do { parts = try DropFrame.parseHead(body.prefix(DropFrame.prefixLength + DropFrame.maxHeadBytes), total: body.count) }
        catch DropFrame.Failure.headTooLarge { return refuse(413, .tooLarge) }
        catch DropFrame.Failure.blobTooLarge { return refuse(413, .tooLarge) }
        catch { return refuse(400, .malformed) }
        guard parts.blobLength <= limits.maxDropBlobBytes else { return refuse(413, .tooLarge) }
        guard let signed = Optional(parts.descriptor), let raw = signed.object?["o"]?.object, let d = try? DropDescriptor(object: raw), d.object == id,
              d.spaceKind == "workspace", !parts.wraps.isEmpty else { return refuse(400, .malformed) }
        guard d.authorID == session.id, (d.authorKind == "device") == (session.kind == .device),
              dropAllowed(session, workspace: d.space, write: true) else { return refuse(403, .notEligible) }
        let key = session.kind == .device ? devices[session.id]?.info?.signingKey : workspaces[session.id]?.card?.wsk
        guard let key, (try? DropDescriptor.verify(signed, authorKey: key)) != nil else { return refuse(401, .badSignature) }
        let existing = drops[id] ?? []
        if let head = existing.last, session.kind == .device, case .ids(let ids) = head.parsed.recipients, !ids.contains(head.parsed.space),
           !ids.contains(session.id), head.parsed.authorID != session.id { return refuse(403, .notEligible) }
        if existing.first.map({ $0.parsed.space != d.space }) == true { return refuse(403, .notEligible) }
        if dropTombstone(id) != nil { return refuse(410, .expired) }
        let now = wall.nowMs
        // the exact retry: the stored version has this very descriptor
        if d.version >= 1, Int(d.version) <= existing.count, (try? canonicalJSON(existing[Int(d.version) - 1].descriptor)) == (try? canonicalJSON(signed)) {
            return ok(200, ["version": .int(Int64(d.version))], etag: d.version)
        }
        guard claims[id] == nil else { return refuse(403, .notEligible) }
        // file/document rules
        if d.objectKind == "document" {
            guard d.expiresMs == nil, d.recipients != .inbox else { return refuse(400, .malformed) }
        } else {
            guard d.version == 1, let e = d.expiresMs else { return refuse(400, .malformed) }
            if e <= now { return refuse(410, .expired) }
            guard e <= now + Self.dropWindowMs, e >= now + Self.dropMinLifeMs else { return refuse(400, .malformed) }
        }
        if case .ids(let ids) = d.recipients {
            let members = workspaces[d.space]?.members.keys.map { $0 } ?? []
            guard !ids.isEmpty, ids.allSatisfy({ $0 == d.space || members.contains($0) }) else { return refuse(400, .malformed) }
        }
        guard parts.wraps.count <= DropFrame.maxWraps, let wraps = try? parts.wraps.map(DropWrapRecord.init(json:)),
              wraps.allSatisfy({ $0.object == id && $0.version == d.version && $0.targetKind != .sk }),
              Set(wraps.map { "\($0.targetKind.rawValue)|\($0.target.hex)|\($0.keyVersion)" }).count == wraps.count else { return refuse(400, .malformed) }
        let isInbox = d.recipients == .inbox
        if isInbox {
            guard !wraps.contains(where: { $0.targetKind == .wk }), wraps.filter({ $0.targetKind == .wxk }).count == 1 else { return refuse(400, .malformed) }
        } else if session.kind == .device {
            guard wraps.contains(where: { $0.targetKind == .wk }) else { return refuse(400, .malformed) }
        }
        for w in wraps {
            switch w.targetKind {
            case .wk:
                guard w.target == d.space else { return refuse(400, .malformed) }
                if let e = workspaces[d.space]?.currentEpoch, w.keyVersion != e { return refuse(409, .staleEpoch, extra: ["epoch": .int(Int64(e))]) }
                if limits.dropRefusesWKWhileRotationDue, session.kind == .device, workspaces[d.space]?.rotationDue.isEmpty == false,
                   let e = workspaces[d.space]?.currentEpoch { return refuse(409, .rotationRequired, extra: ["epoch": .int(Int64(e))]) }
            case .wxk:
                guard w.target == d.space else { return refuse(400, .malformed) }
                if let wv = workspaces[d.space]?.card?.verified?.wxkVersion, w.keyVersion != wv { return refuse(409, .badWxkVersion) }
            case .device:
                guard w.keyVersion == 0 else { return refuse(400, .malformed) }
                guard w.target == d.authorID || workspaces[d.space]?.members[w.target] != nil else { return refuse(403, .notEligible) }
            case .sk: return refuse(400, .malformed)
            }
        }
        let blob = body.suffix(parts.blobLength)
        guard Int64(blob.count) == d.contentLen, d.matches(blob: Data(blob)) else { return refuse(400, .malformed) }
        var state = DropDocument.State(current: existing.last?.parsed.version ?? 0, head: existing.last?.parsed.raw)
        let reply = DropDocument.checkPut(state: &state, ifMatch: ifMatch, descriptor: d.raw)
        guard reply.status == 201 else { return refuse(409, .versionConflict, extra: ["current": .int(Int64(reply.current ?? 0))]) }
        if let refusal = dropQuota(d, session: session, blobCount: blob.count, headCount: parts.headLength, isNewObject: existing.isEmpty) { return refusal }
        if limits.dropUploadsPerMinute > 0 {
            var w = dropUploadWindows[session.id, default: Window()]
            let allowed = w.hit(now: now, limit: limits.dropUploadsPerMinute)
            dropUploadWindows[session.id] = w
            if !allowed { return limited(now) }
        }
        drops[id, default: []].append(DropVersion(descriptor: signed, parsed: d, wraps: wraps, blob: Data(blob)))
        touchDrop(id, workspace: d.space)
        dropExpirySettled.remove(id)
        return ok(201, ["version": .int(Int64(d.version))], etag: d.version)
    }

    private func quota(_ name: String) -> WireReply {
        refuse(429, .quotaExceeded, headers: ["retry-after": "600"], extra: ["quota": .string(name)])
    }

    private func dropQuota(_ d: DropDescriptor, session: Session, blobCount: Int, headCount: Int, isNewObject: Bool) -> WireReply? {
        if d.objectKind == "document", d.version > limits.maxDropDocVersions { return quota("drop_doc_versions") }
        var wsBlob = 0, wsHead = 0, wsVersions = 0, wsDocs = 0, devBlob = 0, devHead = 0, devVersions = 0, devDocs = 0
        for (id, versions) in drops where dropWorkspace(id) == d.space && dropTombstone(id) == nil {
            let mine = versions.first?.parsed.authorID == session.id
            if versions.first?.parsed.objectKind == "document" { wsDocs += 1; if mine { devDocs += 1 } }
            for (i, v) in versions.enumerated() {
                let author = v.parsed.authorID == session.id
                let blobSize = dropPruned(versions, index: i) ? 0 : v.blob.count
                let head = ((try? canonicalJSON(v.descriptor).count) ?? 0) + v.wraps.reduce(0) { $0 + $1.wrap.count + 65 }
                wsBlob += blobSize; wsHead += head; wsVersions += 1
                if author { devBlob += blobSize; devHead += head; devVersions += 1 }
            }
        }
        if d.objectKind == "document", isNewObject {
            if wsDocs >= limits.dropWorkspaceDocuments { return quota("drop_documents") }
            if session.kind == .device, devDocs >= limits.dropDeviceDocuments { return quota("drop_device_documents") }
        }
        if wsBlob + blobCount > limits.maxDropBytes { return quota("drop_ws") }
        if wsHead + headCount > limits.dropWorkspaceHeadBytes { return quota("drop_head_ws") }
        if wsVersions >= limits.maxDropVersions { return quota("drop_versions") }
        if session.kind == .device {
            if devBlob + blobCount > limits.dropDeviceBytes { return quota("drop_device") }
            if devHead + headCount > limits.dropDeviceHeadBytes { return quota("drop_device_head") }
            if devVersions >= limits.dropDeviceVersions { return quota("drop_device_versions") }
        }
        return nil
    }

    // MARK: wraps, claim, retire

    private func dropPutWraps(_ r: WireRequest, _ idText: String, _ versionText: String, _ query: String?, _ session: Session) -> WireReply {
        guard query == nil, let id = ID16(hex: idText), let n = HostAPI.parseDecimal(versionText), n > 0 else { return refuse(400, .malformed) }
        guard session.kind == .workspace else { return refuse(403, .notEligible) }
        guard let o = try? StrictJSON.parse(r.body, maxBytes: 16 << 10).object, Set(o.keys) == ["wraps"], let list = o["wraps"]?.array, list.count == 1,
              let wrap = try? DropWrapRecord(json: list[0]), wrap.object == id, UInt64(wrap.version) == n else { return refuse(400, .malformed) }
        guard let versions = drops[id] else { return refuse(404, .notFound) }
        guard let ws = dropWorkspace(id), ws == session.id else { return refuse(403, .notEligible) }
        if dropTombstone(id) != nil { return refuse(410, .expired) }
        guard n <= UInt64(versions.count) else { return refuse(404, .notFound) }
        let v = versions[Int(n) - 1]
        let addressed = v.parsed.space == session.id || (v.parsed.recipients == .inbox && v.wraps.contains { $0.targetKind == .wxk && $0.target == session.id })
        guard addressed, claims[id].map({ $0 == session.id }) ?? (v.parsed.recipients != .inbox) else { return refuse(403, .notEligible) }
        guard wrap.targetKind == .wk, wrap.target == session.id else { return refuse(400, .malformed) }
        if let e = workspaces[session.id]?.currentEpoch, wrap.keyVersion != e { return refuse(409, .staleEpoch, extra: ["epoch": .int(Int64(e))]) }
        if let stored = v.wraps.first(where: { $0.targetKind == .wk && $0.target == wrap.target && $0.keyVersion == wrap.keyVersion }) {
            if stored == wrap { return json(200) }
            return refuse(409, .wrapConflict, extra: ["wrap": .string(B64U.encode(stored.wrap)), "dek_commit": .string(B64U.encode(v.parsed.dekCommit))])
        }
        drops[id]![Int(n) - 1].wraps.append(wrap)
        touchDrop(id, workspace: session.id)
        return json(200)
    }

    private func dropClaim(_ r: WireRequest, _ idText: String, _ query: String?, _ session: Session) -> WireReply {
        guard query == nil, let id = ID16(hex: idText) else { return refuse(400, .malformed) }
        guard session.kind == .workspace, var versions = drops[id], var v = versions.last else { return refuse(403, .notEligible) }
        if dropTombstone(id) != nil { return refuse(410, .expired) }
        guard v.parsed.recipients == .inbox, v.parsed.objectKind == "file" else { return refuse(403, .notEligible) }
        guard let claim = try? StrictJSON.parse(r.body, maxBytes: 16 << 10) else { return refuse(400, .malformed) }
        guard claim.object?["o"]?.object?["workspace_id"] == .string(session.id.hex) else { return refuse(403, .notEligible) }
        var stored = DropClaim.Stored(object: id, version: v.parsed.version, state: claims[id].map { .claimed(by: $0) } ?? .inbox, wraps: v.wraps)
        let result = DropClaim.check(stored: &stored, claim: claim, cards: workspaces.compactMapValues { $0.card?.wsk }, epochs: workspaces.compactMapValues { $0.currentEpoch })
        if result.status == 200, claims[id] == nil {
            claims[id] = result.claimedBy
            for i in versions.indices { versions[i].wraps = [] }
            v.wraps = stored.wraps; versions[versions.count - 1] = v; drops[id] = versions
            touchDrop(id, workspace: result.claimedBy ?? session.id)
        }
        var fields: [String: JSONValue] = [:]
        if let e = result.error { fields["error"] = .string(e) }
        if let by = result.claimedBy { fields["claimed_by"] = .string(by.hex) }
        else if result.error == "already_claimed" { fields["claimed_by"] = .null }      // section 14: `claimed_by` is always present
        return result.status == 200 ? json(200, fields) : (try? WireReply(status: result.status, body: canonicalJSON(.object(fields)))) ?? refuse(500, .malformed)
    }

    /// Host-only retire (A1): `{expect_version, expect_head}`; both must match the stored head, else 409 `version_conflict`.
    private func dropRetire(_ r: WireRequest, _ idText: String, _ query: String?, _ session: Session) -> WireReply {
        guard query == nil, let id = ID16(hex: idText) else { return refuse(400, .malformed) }
        guard session.kind == .workspace else { return refuse(403, .notEligible) }
        guard let o = try? StrictJSON.parse(r.body, maxBytes: 16 << 10).object, Set(o.keys) == ["expect_version", "expect_head"],
              let ev = o["expect_version"]?.int, ev >= 0, let eh = o["expect_head"]?.string, let head = B64U.decode(eh, length: 32), B64U.encode(head) == eh else { return refuse(400, .malformed) }
        guard let versions = drops[id], let last = versions.last else { return refuse(404, .notFound) }
        guard dropWorkspace(id) == session.id else { return refuse(403, .notEligible) }
        let state = dropTombstone(id)
        let hash = (try? DropDescriptor.parentHash(of: last.parsed.raw)) ?? Data()
        guard Int64(last.parsed.version) == ev, hash == head else {
            return refuse(409, .versionConflict, extra: ["current": .int(Int64(last.parsed.version)), "state": .string(state?.state ?? "live")])
        }
        if let s = state { return json(200, ["state": .string(s.state)]) }
        dropRetiredMs[id] = wall.nowMs
        for i in drops[id]!.indices { drops[id]![i].wraps = []; drops[id]![i].blob = Data() }
        touchDrop(id, workspace: session.id)
        return json(200, ["state": "retired"])
    }

    // MARK: host rewrap (in-process stand-ins used by FakeHost)

    func rewrapSource(object: ID16, version: UInt32, workspace: ID16, token: String) throws -> (DropDescriptor, [DropWrapRecord]) {
        guard try workspaceSession(token) == workspace, let versions = drops[object], version > 0, version <= versions.count,
              dropTombstone(object) == nil else { throw DropError.unauthorized }
        let v = versions[Int(version) - 1]
        let addressed = v.parsed.space == workspace || (v.parsed.recipients == .inbox && v.wraps.contains { $0.targetKind == .wxk && $0.target == workspace })
        guard claims[object].map({ $0 == workspace }) ?? addressed else { throw DropError.unauthorized }
        if case .ids(let ids) = v.parsed.recipients, !ids.contains(workspace) { throw DropError.unauthorized }
        return (v.parsed, v.wraps)
    }

    func putRewrap(_ wrap: DropWrapRecord, token: String) throws {
        let ws = try workspaceSession(token)
        let (descriptor, _) = try rewrapSource(object: wrap.object, version: wrap.version, workspace: ws, token: token)
        guard descriptor.recipients != .inbox || claims[wrap.object] == ws else { throw DropError.unavailableKey }
        guard wrap.targetKind == .wk, wrap.target == ws, wrap.keyVersion == workspaces[ws]?.currentEpoch else { throw Refusal.malformed }
        let i = Int(wrap.version) - 1
        if let stored = drops[wrap.object]?[i].wraps.first(where: { $0.targetKind == .wk && $0.target == ws && $0.keyVersion == wrap.keyVersion }) {
            if stored == wrap { return }
            throw ClientError.relay(RelayRefusal(status: 409, code: .wrapConflict))
        }
        drops[wrap.object]?[i].wraps.append(wrap)
        touchDrop(wrap.object, workspace: ws)
    }
}
