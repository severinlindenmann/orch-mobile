import CryptoKit
import Foundation

/// ORB2 bridge envelope (section 8.1 and 8.2): codec, sealing and opening, and the device's check of a response chunk
/// (section 8.8). Pure: no transport, no clock, no storage.
public enum Bridge {
    public static let magic = Data("ORB2".utf8)
    public static let version: UInt8 = 2
    public static let headerLength = 108
    public static let tagLength = 16
    public static let signatureLength = 64
    public static let overhead = headerLength + tagLength + signatureLength          // 188
    public static let maxRequest = 1 << 20
    public static let maxChunk = 256 * 1024
    public static let maxMeta = 64 * 1024
    public static let windowMs: Int64 = 300_000
    public static let maxOffsetMs: Int64 = 24 * 3600 * 1000

    public enum Direction: UInt8, Sendable { case toHost = 1, toDevice = 2 }

    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let last = Flags(rawValue: 0x01)
        public static let stream = Flags(rawValue: 0x02)
        public static let refusal = Flags(rawValue: 0x04)
    }

    /// The 108-byte header. It is the AAD and is covered by the signature. `magic`, `version`, `direction` and `flags`
    /// are kept raw so that a reader can report why it dropped an envelope.
    public struct Header: Equatable, Sendable {
        public var magic: Data
        public var version: UInt8
        public var direction: UInt8
        public var flags: UInt8
        public var suite: UInt8
        public var workspace: ID16
        public var device: ID16
        public var rid: ID16
        public var stream: ID16
        public var seq: UInt64
        public var tsMs: UInt64
        public var epoch: UInt32
        public var salt: Data

        public init(direction: Direction, flags: Flags = [], workspace: ID16, device: ID16, rid: ID16, stream: ID16? = nil,
                    seq: UInt64, tsMs: UInt64, epoch: UInt32, salt: Data = Header.freshSalt()) {
            self.magic = Bridge.magic; self.version = Bridge.version; self.direction = direction.rawValue
            self.flags = flags.rawValue; self.suite = Suite2.id; self.workspace = workspace; self.device = device
            self.rid = rid; self.stream = stream ?? ID16(bytes: Data(count: 16))!; self.seq = seq; self.tsMs = tsMs
            self.epoch = epoch; self.salt = salt
        }

        init(magic: Data, version: UInt8, direction: UInt8, flags: UInt8, suite: UInt8, workspace: ID16, device: ID16, rid: ID16,
             stream: ID16, seq: UInt64, tsMs: UInt64, epoch: UInt32, salt: Data) {
            self.magic = magic; self.version = version; self.direction = direction; self.flags = flags; self.suite = suite
            self.workspace = workspace; self.device = device; self.rid = rid; self.stream = stream; self.seq = seq
            self.tsMs = tsMs; self.epoch = epoch; self.salt = salt
        }

        /// 16 CSPRNG bytes. Must be fresh for every envelope.
        public static func freshSalt() -> Data {
            var g = SystemRandomNumberGenerator()
            return Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &g) })
        }

        public var flagSet: Flags { Flags(rawValue: flags) }

        public func encode() -> Data {
            precondition(magic.count == 4 && salt.count == 16)
            var out = Data(capacity: Bridge.headerLength)
            out.append(magic)
            out.append(contentsOf: [version, direction, flags, suite])
            for id in [workspace, device, rid, stream] { out.append(id.bytes) }
            out.append(Bytes.u64(seq)); out.append(Bytes.u64(tsMs)); out.append(Bytes.u32(epoch)); out.append(salt)
            return out
        }

        /// Exactly 108 bytes, else `malformed`. Does not judge magic, version, direction or flags.
        public static func decode(_ b: Data) throws -> Header {
            guard b.count == Bridge.headerLength else { throw Refusal.malformed }
            let d = Data(b)
            func id(_ o: Int) -> ID16 { ID16(bytes: d.subdata(in: o..<o + 16))! }
            return Header(magic: d.subdata(in: 0..<4), version: d[4], direction: d[5], flags: d[6], suite: d[7],
                          workspace: id(8), device: id(24), rid: id(40), stream: id(56), seq: Bytes.readU64(d, 72),
                          tsMs: Bytes.readU64(d, 80), epoch: Bytes.readU32(d, 88), salt: d.subdata(in: 92..<108))
        }
    }

    /// An envelope cut into header bytes, body (ciphertext and tag) and signature. Size is checked by the caller's
    /// direction-specific cap.
    public struct Parts: Sendable {
        public let headerBytes: Data
        public let body: Data
        public let signature: Data
        public let header: Header

        public init(envelope e: Data) throws {
            guard e.count >= Bridge.overhead else { throw Refusal.malformed }
            let d = Data(e)
            headerBytes = d.subdata(in: 0..<Bridge.headerLength)
            body = d.subdata(in: Bridge.headerLength..<(d.count - Bridge.signatureLength))
            signature = d.suffix(Bridge.signatureLength)
            header = try Header.decode(headerBytes)
        }

        /// The bytes the signature covers (after the label).
        public var signedPayload: Data { headerBytes + body }
        /// `H(header || body)`, the identity of a stored envelope.
        public var digest: Data { Data(SHA256.hash(data: headerBytes + body)) }
    }

    // MARK: keys and framing

    /// `K_bridge(e)` for epoch >= 1, `K_pair` for epoch 0 (where `stream` is the offer id and `secret` the link secret).
    public static func channelKey(header h: Header, wk: SymmetricKey? = nil, pairSecret: SymmetricKey? = nil) -> SymmetricKey? {
        if h.epoch == 0 { return pairSecret.map { KDF.kPair(secret: $0, workspace: h.workspace, offer: h.stream) } }
        return wk.map { KDF.kBridge(wk: $0, workspace: h.workspace, epoch: h.epoch) }
    }

    /// `HKDF(channel key, salt = header.salt, "orch/v2/bridge-msg")`
    public static func messageKey(channelKey: SymmetricKey, salt: Data) -> SymmetricKey {
        KDF.hkdf(ikm: channelKey, salt: salt, info: Data(Label.kdfBridgeMsg.utf8))
    }

    /// `u32(meta_len) || cj(meta) || data`, `meta_len <= 65536`.
    public static func frame(meta: JSONValue, data: Data = Data()) throws -> Data {
        guard meta.object != nil else { throw Refusal.malformed }
        let m = try canonicalJSON(meta)
        guard m.count <= maxMeta else { throw Refusal.malformed }
        return Bytes.u32(UInt32(m.count)) + m + data
    }

    /// Strict meta (section 2.3): an object, at most 64 KiB, declared length within the plaintext.
    public static func unframe(_ plaintext: Data) throws -> (meta: JSONValue, data: Data) {
        let pt = Data(plaintext)
        guard pt.count >= 4 else { throw Refusal.malformed }
        let n = Int(Bytes.readU32(pt, 0))
        guard n <= maxMeta, 4 + n <= pt.count else { throw Refusal.malformed }
        guard let meta = try? StrictJSON.parse(pt.subdata(in: 4..<4 + n), maxBytes: maxMeta), meta.object != nil else {
            throw Refusal.malformed
        }
        return (meta, pt.subdata(in: 4 + n..<pt.count))
    }

    // MARK: seal and open

    /// `header || AES-256-GCM(K_msg, zero nonce, plaintext, AAD = header) || Sign(signer, label || header || body)`.
    /// The header (with its fresh salt) is built by the caller. Package-visible: signing is custody's.
    package static func seal(header: Header, channelKey: SymmetricKey, signer: some Signer, plaintext: Data) throws -> Data {
        guard header.suite == Suite2.id, header.salt.count == 16 else { throw CryptoFailure.invalidLength }
        let hb = header.encode()
        let body = try ZeroNonceGCM.seal(key: messageKey(channelKey: channelKey, salt: header.salt), plaintext: plaintext, aad: hb)
        let sig = try Signature.sign(signer, label: Label.sigBridge, message: hb + body)
        return hb + body + sig
    }

    /// Opens the body under the header as AAD. Throws `authenticationFailed` on any mismatch.
    public static func openBody(_ parts: Parts, channelKey: SymmetricKey) throws -> Data {
        try ZeroNonceGCM.open(key: messageKey(channelKey: channelKey, salt: parts.header.salt), blob: parts.body, aad: parts.headerBytes)
    }

    public static func verifySignature(_ parts: Parts, key: SigningPublicKey) -> Bool {
        Signature.verify(key, signature: parts.signature, label: Label.sigBridge, message: parts.signedPayload)
    }

    // MARK: device side: section 8.8

    /// What a device holds for one workspace while it reads responses.
    public struct DeviceContext: Sendable {
        public var workspace: ID16
        public var device: ID16
        public var wsk: SigningPublicKey
        public var wk: [UInt32: SymmetricKey]
        public var offsetMs: Int64
        public init(workspace: ID16, device: ID16, wsk: SigningPublicKey, wk: [UInt32: SymmetricKey], offsetMs: Int64 = 0) {
            self.workspace = workspace; self.device = device; self.wsk = wsk; self.wk = wk; self.offsetMs = offsetMs
        }
    }

    /// A request awaiting its response chunks.
    public struct PendingRequest: Equatable, Sendable {
        public var next: UInt64
        public var stream: Bool
        public var epoch: UInt32
        public var offsetAdopted: Bool
        public init(next: UInt64 = 0, stream: Bool = false, epoch: UInt32, offsetAdopted: Bool = false) {
            self.next = next; self.stream = stream; self.epoch = epoch; self.offsetAdopted = offsetAdopted
        }
    }

    /// Where the transport says this chunk came from (mailbox id, index, last, stream).
    public struct MailboxPosition: Equatable, Sendable {
        public var id: ID16
        public var index: UInt64
        public var last: Bool
        public var stream: Bool
        public init(id: ID16, index: UInt64, last: Bool, stream: Bool) {
            self.id = id; self.index = index; self.last = last; self.stream = stream
        }
    }

    public enum DropReason: Equatable, Sendable {
        case size, versionDirectionOrFlags, flags, notForThisDevice, unknownRequest, epochMismatch, mailboxMismatch
        case noKey, hostSignature(pinFailure: Bool), tag, outOfOrder, staleTimestamp, staleEpochNotHigher

        /// The vectors' `why` spelling.
        public var code: String {
            switch self {
            case .size: return "size"
            case .versionDirectionOrFlags: return "version_direction_or_flags"
            case .flags: return "flags"
            case .notForThisDevice: return "not_for_this_device"
            case .unknownRequest: return "unknown_request"
            case .epochMismatch: return "epoch_mismatch"
            case .mailboxMismatch: return "mailbox_mismatch"
            case .noKey: return "no_key"
            case .hostSignature: return "host_signature"
            case .tag: return "tag"
            case .outOfOrder: return "out_of_order"
            case .staleTimestamp: return "stale_timestamp"
            case .staleEpochNotHigher: return "stale_epoch_not_higher"
            }
        }
    }

    public struct Accepted: Equatable, Sendable {
        public let last: Bool
        public let refusal: Bool
        public let meta: JSONValue
        public let data: Data
        /// Adopted from a verified `stale_timestamp` refusal, once per pending rid, within +-24 h.
        public let offsetMs: Int64?
        /// A `stale_timestamp` refusal whose offset exceeds 24 h: the device clock is wrong.
        public let clockWrong: Bool
        /// A `stale_epoch` refusal with a strictly higher epoch: fetch grants.
        public let fetchGrants: Bool
    }

    public enum ResponseOutcome: Equatable, Sendable {
        case accept(Accepted)
        case drop(DropReason)
    }

    /// Section 8.8 for one chunk, in the vectors' order. Returns the outcome and the updated pending table (changed on
    /// accept; the rid is removed once its `last` chunk is accepted). `pending` is the table keyed by rid.
    public static func checkResponse(_ envelope: Data, context c: DeviceContext, pending: [ID16: PendingRequest],
                                     mailbox: MailboxPosition, nowMs: Int64) -> (outcome: ResponseOutcome, pending: [ID16: PendingRequest]) {
        func drop(_ r: DropReason) -> (ResponseOutcome, [ID16: PendingRequest]) { (.drop(r), pending) }
        guard envelope.count >= overhead, envelope.count <= maxChunk else { return drop(.size) }
        guard let parts = try? Parts(envelope: envelope) else { return drop(.size) }
        let h = parts.header
        let known = Flags.last.rawValue | Flags.stream.rawValue | Flags.refusal.rawValue
        if !h.magic.elementsEqual(magic) || h.version != version || h.direction != Direction.toDevice.rawValue || h.flags & ~known != 0 {
            return drop(.versionDirectionOrFlags)
        }
        if h.flagSet.contains(.refusal) && !h.flagSet.contains(.last) { return drop(.flags) }
        if h.suite != Suite2.id || h.workspace != c.workspace || h.device != c.device { return drop(.notForThisDevice) }
        guard var pend = pending[h.rid] else { return drop(.unknownRequest) }
        if h.epoch != pend.epoch { return drop(.epochMismatch) }
        if mailbox.id != h.rid || mailbox.index != h.seq || mailbox.last != h.flagSet.contains(.last)
            || mailbox.stream != h.flagSet.contains(.stream) || pend.stream != mailbox.stream { return drop(.mailboxMismatch) }
        guard let wk = c.wk[h.epoch], let key = channelKey(header: h, wk: wk) else { return drop(.noKey) }
        guard verifySignature(parts, key: c.wsk) else {
            // a tag that opens under the channel key means a member device signed it: that counts as a pin failure
            let pinFailure = (try? openBody(parts, channelKey: key)) != nil
            return drop(.hostSignature(pinFailure: pinFailure))
        }
        guard let plain = try? openBody(parts, channelKey: key), let (meta, data) = try? unframe(plain) else { return drop(.tag) }
        if h.seq != pend.next { return drop(.outOfOrder) }

        var offset: Int64?, clockWrong = false
        let isRefusal = h.flagSet.contains(.refusal)
        let refusalCode = meta["refusal"].string
        if isRefusal, !pend.offsetAdopted, refusalCode.map({ $0.bytesEqual("stale_timestamp") }) == true, let hostMs = meta["host_ms"].int {
            do {
                pend.offsetAdopted = true
                let off = hostMs.subtractingReportingOverflow(nowMs)
                if !off.overflow, off.partialValue >= -maxOffsetMs, off.partialValue <= maxOffsetMs { offset = off.partialValue } else { clockWrong = true }
            }
        } else {
            let local = saturatingAdd(nowMs, c.offsetMs)
            let ts = h.tsMs > UInt64(Int64.max) ? Int64.max : Int64(h.tsMs)
            let diff = local.subtractingReportingOverflow(ts)
            if diff.overflow || diff.partialValue < -windowMs || diff.partialValue > windowMs { return drop(.staleTimestamp) }
        }
        var fetch = false
        if isRefusal, refusalCode.map({ $0.bytesEqual("stale_epoch") }) == true {
            // section 8.5: only a strictly higher epoch sends the device to fetch grants; it never moves backwards
            guard let e = meta["epoch"].int, e > Int64(h.epoch) else { return drop(.staleEpochNotHigher) }
            fetch = true
        }
        pend.next += 1
        var table = pending
        // the last chunk completes the request: retire the rid so no further chunk (even a signed one) is accepted for it
        table[h.rid] = h.flagSet.contains(.last) ? nil : pend
        return (.accept(Accepted(last: h.flagSet.contains(.last), refusal: isRefusal, meta: meta, data: data, offsetMs: offset,
                                 clockWrong: clockWrong, fetchGrants: fetch)), table)
    }
}

private extension JSONValue {
    subscript(_ k: String) -> JSONValue { object?[k] ?? .null }
}
