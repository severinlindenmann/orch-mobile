import Foundation
import OrchProtocol

/// A parsed pairing link (protocol section 4 and 8.3 step 1): the five-field fragment and the relay origin it was found at.
/// The origin is only what the link says; a person reviews it, and it is later compared byte for byte with the verified card's
/// `relay_url`. The secret `S` never appears in a description.
public struct PairingLink: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public enum Failure: Error, Equatable, Sendable {
        /// Not a pairing link at all (scheme, path, query, userinfo or fragment shape).
        case malformed
        /// The fragment is not exactly `v2.<ws>.<offer>.<S>.<wsk_pin>.<pk_pin>` in canonical spellings.
        case badFragment
        /// No origin the link can be trusted to name (an `orch://` link without exactly one `relay` parameter, or an origin that is
        /// not a section 7.1 origin).
        case badOrigin
    }

    public let origin: String
    public let workspace: ID16
    public let offer: ID16
    package let secret: Data
    package let wskPin: Data
    package let pkPin: Data

    package init(origin: String, workspace: ID16, offer: ID16, secret: Data, wskPin: Data, pkPin: Data) {
        self.origin = origin; self.workspace = workspace; self.offer = offer; self.secret = secret; self.wskPin = wskPin; self.pkPin = pkPin
    }

    public var description: String { "PairingLink(origin: \(origin), workspace: \(workspace.hex), offer: \(offer.hex), <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["origin": origin, "workspace": workspace.hex], displayStyle: .struct) }

    /// The reviewed origin as a person reads it (ASCII; an IDN host is shown in punycode, never decoded).
    public var reviewedOrigin: String { origin }

    // MARK: fragment (vectors bridge.links)

    struct Fields: Equatable {
        let workspace: ID16, offer: ID16
        let secret: Data, wskPin: Data, pkPin: Data
    }

    /// Strict: an optional single leading `#`, exactly six dot-separated parts, `v2`, lower-case hex ids, and canonical 43-character
    /// b64u of 32 bytes for each of the last three.
    static func parseFragment(_ text: String) -> Fields? {
        var f = Substring(text)
        if f.first == "#" { f = f.dropFirst() }
        let parts = f.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 6, parts[0].utf8Equal("v2"), let ws = ID16(hex: parts[1]), let offer = ID16(hex: parts[2]) else { return nil }
        func pin(_ s: String) -> Data? { s.utf8.count == 43 ? B64U.decode(s, length: 32) : nil }
        guard let secret = pin(parts[3]), let wsk = pin(parts[4]), let pk = pin(parts[5]) else { return nil }
        return Fields(workspace: ws, offer: offer, secret: secret, wskPin: wsk, pkPin: pk)
    }

    // MARK: whole link

    /// `https://<relay>/app/pair#...` (canonical) or `/pair#...` (alias), and `orch://pair?relay=<percent-encoded origin>#...`
    /// (compatibility, D-3: only with an explicit relay origin). No userinfo, no extra query, no extra path.
    public static func parse(_ text: String) throws -> PairingLink {
        guard text.utf8.allSatisfy({ $0 >= 0x21 && $0 < 0x7F }), text.utf8.count <= 2048 else { throw Failure.malformed }
        guard let hash = text.firstIndex(of: "#") else { throw Failure.malformed }
        let head = String(text[..<hash])
        let frag = String(text[text.index(after: hash)...])
        guard !frag.contains("#"), let fields = parseFragment(frag) else { throw Failure.badFragment }
        let origin: String
        if let rest = head.stripPrefix("orch://") {
            // orch://pair?relay=<origin>
            let (host, query) = split(rest, at: "?")
            guard host == "pair", let query else { throw Failure.badOrigin }
            let items = query.split(separator: "&", omittingEmptySubsequences: false).map(String.init)
            guard items.count == 1, let value = items[0].stripPrefix("relay="), !value.isEmpty,
                  let decoded = percentDecode(value), RelayURL.isValid(decoded) else { throw Failure.badOrigin }
            origin = decoded
        } else if let scheme = head.stripPrefix("https://") ?? head.stripPrefix("http://") {
            let isHTTPS = head.hasPrefix("https://")
            let (authority, path) = split(scheme, at: "/")
            guard !authority.contains("@"), !authority.isEmpty, let path else { throw Failure.malformed }
            guard path == "app/pair" || path == "pair" else { throw Failure.malformed }
            let o = (isHTTPS ? "https://" : "http://") + authority
            guard RelayURL.isValid(o) else { throw Failure.badOrigin }
            origin = o
        } else { throw Failure.malformed }
        return PairingLink(origin: origin, workspace: fields.workspace, offer: fields.offer, secret: fields.secret, wskPin: fields.wskPin, pkPin: fields.pkPin)
    }

    private static func split(_ s: String, at c: Character) -> (String, String?) {
        guard let i = s.firstIndex(of: c) else { return (s, nil) }
        return (String(s[..<i]), String(s[s.index(after: i)...]))
    }

    /// Strict `%XX` decoding of a single query value (upper- or lower-case hex); a stray `%` is a failure, and the result must be ASCII.
    private static func percentDecode(_ s: String) -> String? {
        var out = [UInt8](); let u = Array(s.utf8); var i = 0
        func hex(_ c: UInt8) -> UInt8? {
            switch c { case 0x30...0x39: c - 0x30; case 0x41...0x46: c - 0x41 + 10; case 0x61...0x66: c - 0x61 + 10; default: nil }
        }
        while i < u.count {
            if u[i] == 0x25 {
                guard i + 2 < u.count else { return nil }
                guard let a = hex(u[i + 1]), let b = hex(u[i + 2]) else { return nil }
                out.append(a << 4 | b); i += 3
            } else { out.append(u[i]); i += 1 }
        }
        guard out.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else { return nil }
        return String(decoding: out, as: UTF8.self)
    }
}

private extension String {
    func stripPrefix(_ p: String) -> String? { hasPrefix(p) ? String(dropFirst(p.count)) : nil }
}
