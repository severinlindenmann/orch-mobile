import Foundation

/// A strict, incremental HTTP/1.1 response parser. It is the ONLY place a relay reply's framing is interpreted: nothing decodes a
/// content encoding, nothing follows anything, and the body buffer never grows past `maxBody` (every path checks BEFORE appending).
///
/// Limits and refusals:
/// - Header block (status line through the blank line) at most 16 KiB, at most 64 header fields.
/// - CRLF line endings only: a bare LF or bare CR anywhere in the head or in chunk framing is a violation. No obs-fold (a field line
///   starting with SP or HT). Field names are tokens (case-insensitive, kept lower-case) with no space before the colon; values carry no
///   control characters. Duplicates are kept as received until validated.
/// - Status line `HTTP/1.1 NNN [reason]` (also 1.0). Interim 100 and 103 replies are skipped (at most 4, at most 16 KiB of head bytes
///   in all, no body framing allowed on them); 101 and any other 1xx are refused. This client never sends `Expect: 100-continue`.
/// - Any `Content-Encoding` (EVERY occurrence) other than exactly `identity` is refused as `tooLarge`: nothing is decoded, so there is
///   nothing to bound.
/// - `Transfer-Encoding` must be exactly one field whose whole value is `chunked` (case-insensitive): parameters, repetition and other
///   codings are refused. `Content-Length` together with `Transfer-Encoding` is refused. More than one `Content-Length` field is refused
///   (even with equal values); a value must be ASCII digits only (leading zeros fine; no sign, space, comma list or overflow), and one
///   over `maxBody` is `tooLarge` at the headers, before any body byte is read.
/// - 204 and 304 end at the headers; 204 carrying Content-Length or Transfer-Encoding is refused; 205 must be empty (Content-Length 0
///   or absent, no Transfer-Encoding).
/// - A final reply with neither Content-Length nor chunked coding is refused (a close-delimited body's completeness cannot be shown).
/// - Chunked bodies: the size line is 1 to 8 hex digits, optionally followed by `;` and printable extension bytes, at most 128 bytes in
///   all; a chunk that would push the body past `maxBody` is `tooLarge` before its data is taken; each chunk's data is followed by
///   exactly CRLF; at most 1024 chunks and 32 KiB of framing overhead; the trailer section is bounded (16 lines, 8 KiB) and its fields
///   are discarded, so they can never override framing or any header.
/// - A stream that ends before the message does is a violation (`.disconnected` to the caller). Bytes after the end of the message are
///   ignored (one request per connection).
struct HTTP1ResponseParser {
    enum Failure: Error, Equatable {
        /// The body or a declared length is over the cap, or a content encoding was refused.
        case tooLarge
        /// Anything else wrong with the reply, including a stream that ends before the message does.
        case violation(String)
    }

    static let maxHeaderBlock = 16 << 10
    static let maxHeaders = 64
    static let maxChunkLine = 128
    static let maxChunks = 1024
    static let maxChunkOverhead = 32 << 10
    static let maxInterim = 4
    static let maxTrailerLines = 16
    static let maxTrailerBytes = 8 << 10

    private enum Phase { case head, length(Int), chunkSize, chunkData(Int), chunkDataEnd, trailers, done }

    let maxBody: Int
    private var phase = Phase.head
    private var buffer: [UInt8] = []
    private var trailerLines = 0, trailerBytes = 0
    private var headScanned = 0                   // bytes of `buffer` already searched and line-ending checked
    private var isHTTP10 = false
    private var interimCount = 0, interimBytes = 0
    private var chunkCount = 0, overhead = 0
    private(set) var status = 0
    private(set) var fields: [(name: String, value: String)] = []
    private(set) var body = Data()

    init(maxBody: Int) { self.maxBody = maxBody }

    /// Headers that frame the reply or that a caller may act on: a repeat of one of these is kept so a conflicting repeat is refused.
    static let strictRepeats: Set<String> = ["content-length", "transfer-encoding", "content-encoding", "content-type", "retry-after", "location"]

    /// The fields for the `WireReply`: strict headers keep every occurrence; any other repeated header keeps its first value.
    var replyFields: [(name: String, value: String)] {
        var seen = Set<String>(), out: [(name: String, value: String)] = []
        for f in fields where Self.strictRepeats.contains(f.name) || seen.insert(f.name).inserted { out.append(f) }
        return out
    }

    var isComplete: Bool { if case .done = phase { return true }; return false }

    /// Takes bytes from the socket. Throws on the first violation; after completion further bytes are ignored.
    mutating func feed(_ data: Data) throws {
        if isComplete || data.isEmpty { return }
        switch phase {
        case .head:
            buffer.append(contentsOf: data)
            try parseHead()
        case .length(let n):
            let take = min(n, data.count)
            body.append(data.prefix(take))              // n <= maxBody and body.count + n <= maxBody by construction
            phase = take == n ? .done : .length(n - take)
        case .chunkSize, .chunkData, .chunkDataEnd, .trailers:
            buffer.append(contentsOf: data)
            try parseChunked()
        case .done: break
        }
    }

    /// The peer closed the stream.
    mutating func end() throws {
        switch phase {
        case .done: return
        default: throw Failure.violation("stream ended before the message did")
        }
    }

    // MARK: head

    private mutating func parseHead() throws {
        // Resume from where the last read stopped (a terminator can straddle the boundary: 3 bytes back), not from the start.
        let from = max(headScanned - 3, 0)
        guard let end = Self.find(crlfcrlf: buffer, from: from) else {
            if buffer.count >= Self.maxHeaderBlock { throw Failure.violation("header block over 16 KiB") }
            // a bare LF can already be seen without the terminator
            try Self.checkNoBareLineEndings(buffer, from: max(headScanned - 1, 0), complete: false)
            headScanned = buffer.count
            return
        }
        guard end + 4 <= Self.maxHeaderBlock else { throw Failure.violation("header block over 16 KiB") }
        let block = Array(buffer[0..<end])
        let rest = Array(buffer[(end + 4)...])
        buffer = []; headScanned = 0
        try Self.checkNoBareLineEndings(block, from: 0, complete: true)
        let lines = Self.splitCRLF(block)
        try parseStatus(lines[0])
        if (100...199).contains(status) { try skipInterim(lines: lines, block: block.count + 4, rest: rest); return }
        var seen: [(name: String, value: String)] = []
        for line in lines.dropFirst() {
            guard let first = line.first, first != 0x20, first != 0x09 else { throw Failure.violation("obs-fold") }
            guard let colon = line.firstIndex(of: 0x3A), colon > 0, line[0..<colon].allSatisfy(Self.isTokenByte) else { throw Failure.violation("bad field") }
            var value = Array(line[(colon + 1)...])
            while let f = value.first, f == 0x20 || f == 0x09 { value.removeFirst() }
            while let l = value.last, l == 0x20 || l == 0x09 { value.removeLast() }
            guard value.allSatisfy({ ($0 >= 0x20 || $0 == 0x09) && $0 != 0x7F }) else { throw Failure.violation("control byte in value") }
            seen.append((String(decoding: line[0..<colon], as: UTF8.self).lowercased(), String(decoding: value, as: UTF8.self)))
            if seen.count > Self.maxHeaders { throw Failure.violation("more than 64 fields") }
        }
        fields = seen
        try chooseFraming()
        if !rest.isEmpty { try feed(Data(rest)) }
    }

    /// 100 and 103 are skipped; they may carry no framing and are bounded in number and size.
    private mutating func skipInterim(lines: [[UInt8]], block: Int, rest: [UInt8]) throws {
        guard status == 100 || status == 103 else { throw Failure.violation("interim status \(status)") }
        interimCount += 1; interimBytes += block
        guard interimCount <= Self.maxInterim, interimBytes <= Self.maxHeaderBlock, lines.count <= Self.maxHeaders + 1 else { throw Failure.violation("too many interim replies") }
        for line in lines.dropFirst() {
            let lower = String(decoding: line, as: UTF8.self).lowercased()
            if lower.hasPrefix("content-length") || lower.hasPrefix("transfer-encoding") { throw Failure.violation("framing on an interim reply") }
        }
        status = 0
        buffer = rest; headScanned = 0
        if !rest.isEmpty { try parseHead() }
    }

    private mutating func parseStatus(_ line: [UInt8]) throws {
        let s = String(decoding: line, as: UTF8.self)
        guard s.hasPrefix("HTTP/1.1 ") || s.hasPrefix("HTTP/1.0 ") else { throw Failure.violation("status line") }
        let u = Array(line)
        guard u.count >= 12, u[9...11].allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), u.count == 12 || u[12] == 0x20,
              u[12...].allSatisfy({ $0 >= 0x20 && $0 != 0x7F || $0 == 0x09 }) else { throw Failure.violation("status line") }
        let code = Int(u[9] - 0x30) * 100 + Int(u[10] - 0x30) * 10 + Int(u[11] - 0x30)
        guard (100...599).contains(code) else { throw Failure.violation("status \(code)") }
        status = code
        isHTTP10 = s.hasPrefix("HTTP/1.0 ")
    }

    private mutating func chooseFraming() throws {
        func values(_ name: String) -> [String] { fields.filter { $0.name == name }.map(\.value) }
        // nothing is ever decoded: any encoding but exactly identity is refused at the headers
        for v in values("content-encoding") where v.lowercased() != "identity" { throw Failure.tooLarge }
        let te = values("transfer-encoding"), cl = values("content-length")
        if !te.isEmpty && !cl.isEmpty { throw Failure.violation("content-length with transfer-encoding") }
        if cl.count > 1 { throw Failure.violation("duplicate content-length") }
        if status == 204 {
            guard te.isEmpty, cl.isEmpty else { throw Failure.violation("framing on 204") }
            phase = .done; return
        }
        if status == 304 { phase = .done; return }
        if status == 205, !te.isEmpty { throw Failure.violation("framing on 205") }
        if !te.isEmpty {
            guard !isHTTP10, te.count == 1, te[0].lowercased() == "chunked" else { throw Failure.violation("transfer-encoding") }
            phase = .chunkSize
        } else if let c = cl.first {
            var d = Array(c.utf8)
            guard !d.isEmpty, d.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { throw Failure.violation("content-length") }
            while d.count > 1, d[0] == 0x30 { d.removeFirst() }
            guard d.count <= 18, let n = Int(String(decoding: d, as: UTF8.self)) else { throw Failure.violation("content-length overflow") }
            if status == 205, n != 0 { throw Failure.violation("205 with a body") }
            guard n <= maxBody else { throw Failure.tooLarge }
            phase = n == 0 ? .done : .length(n)
        } else if status == 205 {
            phase = .done
        } else {
            throw Failure.violation("no content-length and not chunked")
        }
    }

    // MARK: chunked

    private mutating func parseChunked() throws {
        while true {
            switch phase {
            case .chunkSize:
                guard let line = try Self.takeLine(&buffer, limit: Self.maxChunkLine) else { return }
                overhead += line.count + 4
                let hex = line.prefix { $0 != 0x3B }
                if hex.count < line.count {                // `;` extension: printable bytes only, ignored
                    guard line[(hex.count + 1)...].allSatisfy({ $0 >= 0x20 && $0 != 0x7F }) else { throw Failure.violation("chunk extension") }
                }
                guard (1...8).contains(hex.count), hex.allSatisfy(Self.isHexByte), let size = Int(String(decoding: hex, as: UTF8.self), radix: 16) else {
                    throw Failure.violation("chunk size")
                }
                chunkCount += 1
                guard chunkCount <= Self.maxChunks, overhead <= Self.maxChunkOverhead else { throw Failure.violation("chunk overhead") }
                if size == 0 { phase = .trailers; continue }
                guard size <= maxBody - body.count else { throw Failure.tooLarge }
                phase = .chunkData(size)
            case .chunkData(let n):
                if buffer.isEmpty { return }
                let take = min(n, buffer.count)
                body.append(contentsOf: buffer[0..<take])
                buffer.removeFirst(take)
                phase = take == n ? .chunkDataEnd : .chunkData(n - take)
            case .chunkDataEnd:
                if buffer.count < 2 { return }
                guard buffer[0] == 0x0D, buffer[1] == 0x0A else { throw Failure.violation("chunk not followed by CRLF") }
                buffer.removeFirst(2)
                phase = .chunkSize
            case .trailers:
                guard let line = try Self.takeLine(&buffer, limit: Self.maxTrailerBytes) else { return }
                if line.isEmpty { phase = .done; buffer = []; return }
                trailerLines += 1; trailerBytes += line.count + 2
                if trailerLines > Self.maxTrailerLines || trailerBytes > Self.maxTrailerBytes { throw Failure.violation("trailers") }
            default: return
            }
        }
    }

    // MARK: helpers

    /// A line up to CRLF, removed from `buf`; nil if incomplete. A LF without CR before it, a CR not before LF, or a line over `limit` fails.
    private static func takeLine(_ buf: inout [UInt8], limit: Int) throws -> [UInt8]? {
        guard let lf = buf.firstIndex(of: 0x0A) else {
            if buf.count > limit { throw Failure.violation("line too long") }
            if buf.contains(0x0D) && buf.last != 0x0D { throw Failure.violation("bare CR") }
            return nil
        }
        guard lf > 0, buf[lf - 1] == 0x0D, lf - 1 <= limit else { throw Failure.violation("bad line ending") }
        let line = Array(buf[0..<(lf - 1)])
        if line.contains(0x0D) { throw Failure.violation("bare CR") }
        buf.removeFirst(lf + 1)
        return line
    }

    private static func find(crlfcrlf b: [UInt8], from: Int) -> Int? {
        guard b.count >= 4 else { return nil }
        var i = from
        while i + 3 < b.count {
            if b[i] == 0x0D, b[i + 1] == 0x0A, b[i + 2] == 0x0D, b[i + 3] == 0x0A { return i }
            i += 1
        }
        return nil
    }

    private static func checkNoBareLineEndings(_ b: [UInt8], from: Int, complete: Bool) throws {
        for i in from..<b.count {
            let c = b[i]
            if c == 0x0A, i == 0 || b[i - 1] != 0x0D { throw Failure.violation("bare LF") }
            if c == 0x0D, i + 1 < b.count, b[i + 1] != 0x0A { throw Failure.violation("bare CR") }
            if c == 0x0D, i + 1 == b.count, complete { throw Failure.violation("bare CR") }
            if c == 0 { throw Failure.violation("NUL") }
        }
    }

    private static func splitCRLF(_ b: [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = [], cur: [UInt8] = [], i = 0
        while i < b.count {
            if b[i] == 0x0D, i + 1 < b.count, b[i + 1] == 0x0A { out.append(cur); cur = []; i += 2 } else { cur.append(b[i]); i += 1 }
        }
        out.append(cur)
        return out
    }

    static func isTokenByte(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || "!#$%&'*+-.^_`|~".utf8.contains(c)
    }
    private static func isHexByte(_ c: UInt8) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66) }
}
