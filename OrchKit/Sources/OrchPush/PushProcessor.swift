import CryptoKit
import Foundation
import OrchProtocol

/// Protocol v2 section 9 (suite 2): everything a notification extension does with a push before it may show text.
/// Pure: no I/O, no clock, no storage. The caller supplies the keys, the replay state and `now`, and persists the
/// returned replay state. Extension-safe: only Foundation, CryptoKit and OrchProtocol.
///
/// Rejected payloads are not handled here. The generic fallback notification (decision A12, a documented native
/// exception to section 9's "drop") is the caller's job.
public enum PushProcessor {
    public static let maxOuterBytes = 3072
    public static let maxAgeMs: Int64 = 24 * 3600 * 1000
    public static let skewMs: Int64 = 300_000
    public static let maxLabelCodePoints = 80
    public static let kinds: [String] = ["question", "question.closed", "ticket.update", "drop.new", "peer.ticket", "join"] // compared by UTF-8 bytes

    /// What a push receiver holds for one workspace: the pinned `WSK` and `K_push(ws, e)` per epoch it holds.
    /// A receiver never needs `WK_e` itself.
    public struct WorkspaceKeys: Sendable {
        public var wsk: SigningPublicKey
        public var kPush: [UInt32: SymmetricKey]
        public init(wsk: SigningPublicKey, kPush: [UInt32: SymmetricKey]) { self.wsk = wsk; self.kPush = kPush }
        /// Derives `K_push` for each held `WK_e` (done once at pairing or at an epoch change).
        public init(wsk: SigningPublicKey, workspace: ID16, wk: [UInt32: SymmetricKey]) {
            self.init(wsk: wsk, kPush: wk.reduce(into: [:]) { $0[$1.key] = KDF.kPush(wk: $1.value, workspace: workspace, epoch: $1.key) })
        }
    }

    public typealias Keyring = [ID16: WorkspaceKeys]

    public struct Payload: Equatable, Sendable {
        public let workspace: ID16
        public let epoch: UInt32
        public let kind: String
        public let id: String
        public let label: String
        public let tsMs: Int64
    }

    /// Why a payload was dropped. Raw values are the vectors' `why`.
    public enum DropReason: String, Sendable, Equatable {
        case size, shape, noKey = "no_key", tag, signature, payload, stale, replay
    }

    public enum Outcome: Equatable, Sendable {
        /// Show `label` with notification tag = `id` (`Payload.id`).
        case show(Payload)
        case drop(DropReason)
    }

    /// The highest `ts_ms` shown per `(ws, id)`, plus the highest `ts_ms` shown at all. A value type: pure functions
    /// take it and return the next one. The caller persists it.
    public struct ReplayState: Equatable, Sendable {
        /// Keyed by the id's UTF-8 bytes, never by `String` (Swift equality is canonical equivalence, the protocol
        /// compares code points).
        public struct Key: Hashable, Sendable {
            public let workspace: ID16
            public let idBytes: Data
            public init(workspace: ID16, id: String) { self.workspace = workspace; self.idBytes = Data(id.utf8) }
        }
        public private(set) var lastShown: [Key: Int64]
        /// The highest `ts_ms` actually shown: host time under the WSK signature, not the local clock. The 24 h lower
        /// bound is `max(nowMs, maxShownTs) - 24 h` and entries older than `maxShownTs - 24 h` are pruned, so winding
        /// the clock back cannot make a pruned push replayable. A wrong local clock cannot move this mark, only a
        /// genuine signed push can (and only within `now + 300 s`).
        public private(set) var maxShownTs: Int64
        public init(lastShown: [Key: Int64] = [:], maxShownTs: Int64 = Int64.min) {
            self.lastShown = lastShown; self.maxShownTs = maxShownTs
        }

        public func last(workspace: ID16, id: String) -> Int64? { lastShown[Key(workspace: workspace, id: id)] }

        func pruned() -> ReplayState {
            let floor = saturatingAdd(maxShownTs, -PushProcessor.maxAgeMs)
            return ReplayState(lastShown: lastShown.filter { $0.value >= floor }, maxShownTs: maxShownTs)
        }

        func recording(_ key: Key, _ ts: Int64) -> ReplayState {
            var next = lastShown; next[key] = ts
            return ReplayState(lastShown: next, maxShownTs: max(maxShownTs, ts)).pruned()
        }
    }

    /// The timestamp rule of section 9 steps 6 and 7 as a pure function: `max(nowMs, maxShownTs) - 24 h <= ts_ms <= nowMs + 300 s`
    /// (inclusive), and strictly higher than the last one shown for `(ws, id)`. `floorNowMs` is
    /// `maxShownTs` (see `ReplayState`); pass `Int64.min` when there is no history.
    public static func checkTimestamp(tsMs: Int64, nowMs: Int64, floorNowMs: Int64, lastShown: Int64?) -> DropReason? {
        guard tsMs >= saturatingAdd(max(nowMs, floorNowMs), -maxAgeMs), tsMs <= saturatingAdd(nowMs, skewMs) else { return .stale }
        if let last = lastShown, tsMs <= last { return .replay }
        return nil
    }

    /// Processes the outer object's bytes. Returns the outcome and the next replay state: pruned and advanced on every
    /// call, with the shown timestamp recorded on `.show`. Only a shown push changes the state.
    public static func process(outer raw: Data, keys: Keyring, replay: ReplayState, nowMs: Int64) -> (result: Outcome, replay: ReplayState) {
        let state = replay.pruned()
        switch open(outer: raw, keys: keys) {
        case .drop(let why): return (.drop(why), state)
        case .show(let p):
            let key = ReplayState.Key(workspace: p.workspace, id: p.id)
            if let why = checkTimestamp(tsMs: p.tsMs, nowMs: nowMs, floorNowMs: state.maxShownTs, lastShown: state.lastShown[key]) {
                return (.drop(why), state)
            }
            return (.show(p), state.recording(key, p.tsMs))
        }
    }

    /// The remote notification carries the outer object as the JSON string under `o`.
    public static func process(o: String, keys: Keyring, replay: ReplayState, nowMs: Int64) -> (result: Outcome, replay: ReplayState) {
        process(outer: Data(o.utf8), keys: keys, replay: replay, nowMs: nowMs)
    }

    /// Steps 1 to 5 of section 9 (size and shape, key, tag, WSK signature, payload shape); no clock, no replay.
    /// The order of the checks is the vectors' order. Returns `.show` with the payload or `.drop`.
    package static func open(outer raw: Data, keys: Keyring) -> Outcome {
        if raw.count > maxOuterBytes { return .drop(.size) }
        guard let m = try? StrictJSON.parse(raw, maxBytes: maxOuterBytes).object, Set(m.keys) == ["v", "ws", "epoch", "c"], m["v"] == .int(2),
              let ws = m["ws"]?.string.flatMap({ ID16(hex: $0) }),
              let c = m["c"]?.string.flatMap({ B64U.decode($0) }),
              let epochInt = m["epoch"]?.int else { return .drop(.shape) }
        guard epochInt >= 0, epochInt <= Int64(UInt32.max),
              let entry = keys[ws], let kPush = entry.kPush[UInt32(epochInt)] else { return .drop(.noKey) }
        let epoch = UInt32(epochInt)

        let aad = Data(Label.aadPush.utf8) + Bytes.u8(Suite2.id) + ws.bytes + Bytes.u32(epoch)
        guard let plain = try? SaltedAEAD.open(key: kPush, msgLabel: Label.kdfPushMsg, aad: aad, blob: c),
              let innerValue = try? StrictJSON.parse(plain, maxBytes: maxOuterBytes) else { return .drop(.tag) }
        // Section 9 step 3: "the tag fails, or `inner` is not exactly {p, sig}" is one drop reason (`tag`).
        guard let inner = innerValue.object, Set(inner.keys) == ["p", "sig"],
              let sig = inner["sig"]?.string.flatMap({ B64U.decode($0, length: Suite2.signatureLength) }),
              let p = inner["p"] else { return .drop(.tag) }
        guard p.object != nil else { return .drop(.payload) }

        guard let cj = try? canonicalJSON(p) else { return .drop(.payload) }
        let signed = Data(Label.sigPush.utf8) + Bytes.u8(Suite2.id) + ws.bytes + Bytes.u32(epoch) + cj
        guard Signature.verify(entry.wsk, signature: sig, message: signed) else { return .drop(.signature) }

        guard let o = p.object, Set(o.keys) == ["kind", "id", "label", "ts_ms"], let kind = o["kind"]?.string,
              kinds.contains(where: { $0.bytesEqual(kind) }),
              let label = o["label"]?.string, label.unicodeScalars.count <= maxLabelCodePoints,
              let id = o["id"]?.string, let ts = o["ts_ms"]?.int else { return .drop(.payload) }
        return .show(Payload(workspace: ws, epoch: epoch, kind: kind, id: id, label: label, tsMs: ts))
    }
}
