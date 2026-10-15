import Foundation
import Testing
@testable import OrchProtocol

@Suite struct DropFrameTests {
    let descriptor: JSONValue = ["o": ["kind": "drop_object"], "sig": "AA"]

    @Test func layoutIsMagicBigEndianLengthHeadBlob() throws {
        let blob = Data((0..<100).map { UInt8($0) })
        let frame = try DropFrame.encode(descriptor: descriptor, wraps: [], blob: blob)
        let head = try canonicalJSON(["descriptor": descriptor, "wraps": []])
        #expect(frame.prefix(4) == Data("ODU2".utf8))
        #expect(Array(frame[4..<8]) == [0, 0, UInt8(head.count >> 8), UInt8(head.count & 255)])
        #expect(frame[8..<(8 + head.count)] == head)
        #expect(frame.suffix(100) == blob)
        let (parts, back) = try DropFrame.parse(frame)
        #expect(parts.total == frame.count && parts.headLength == head.count && back == blob && parts.descriptor == descriptor)
    }

    @Test func malformedFramesAreRefused() throws {
        let frame = try DropFrame.encode(descriptor: descriptor, wraps: [], blob: Data([1]))
        var badMagic = frame; badMagic[3] = UInt8(ascii: "1")
        #expect(throws: DropFrame.Failure.malformed) { _ = try DropFrame.parse(badMagic) }
        #expect(throws: DropFrame.Failure.malformed) { _ = try DropFrame.parse(frame.prefix(6)) }
        var huge = frame; huge.replaceSubrange(4..<8, with: Bytes.u32(UInt32(DropFrame.maxHeadBytes + 1)))
        #expect(throws: DropFrame.Failure.headTooLarge) { _ = try DropFrame.parse(huge) }
        // a head that is not exactly the canonical two-field object
        let loose = Data(#"{"wraps":[],"descriptor":{},"x":1}"#.utf8)
        #expect(throws: DropFrame.Failure.malformed) { _ = try DropFrame.parse(Data("ODU2".utf8) + Bytes.u32(UInt32(loose.count)) + loose) }
    }

    @Test func capsAreEnforcedOnEncode() throws {
        #expect(throws: DropFrame.Failure.blobTooLarge) { _ = try DropFrame.encode(descriptor: descriptor, wraps: [], blob: Data(count: DropFrame.maxBlobBytes + 1)) }
        let big: JSONValue = ["o": .string(String(repeating: "a", count: DropFrame.maxDescriptorBytes)), "sig": "AA"]
        #expect(throws: DropFrame.Failure.descriptorTooLarge) { _ = try DropFrame.head(descriptor: big, wraps: []) }
    }
}
