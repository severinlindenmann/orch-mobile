import Foundation
import Testing
import OrchProtocol
@testable import OrchClient

@Suite struct PhoneEventIDsTests {
    struct Wall: WallClock { let nowMs: Int64 }
    struct Fill: Entropy {
        let byte: UInt8
        func bytes(_ count: Int) -> Data { Data(repeating: byte, count: count) }
    }

    @Test func timeIsWallPlusAdoptedOffsetAndRandomIsEntropy() throws {
        let ids = PhoneEventIDs(wall: Wall(nowMs: 1_790_000_000_000), entropy: Fill(byte: 0xFF))
        let a = try ids.next()
        #expect(ULID.timeMs(of: a) == 1_790_000_000_000)
        #expect(a.hasSuffix("ZZZZZZZZZZZZZZZZ"))
        let b = try ids.next(offsetMs: -12_345)
        let expected: Int64 = 1_789_999_987_655
        #expect(ULID.timeMs(of: b) == expected)
        #expect(ULID.isValid(b))
    }

    @Test func systemEntropyGivesDistinctIDsInTheSameMillisecond() throws {
        let ids = PhoneEventIDs(wall: Wall(nowMs: 1_790_000_000_000))
        let set = Set(try (0..<50).map { _ in try ids.next() })
        #expect(set.count == 50)
    }

    @Test func aWallBeforeTheEpochIsRefusedNotTrapped() {
        let ids = PhoneEventIDs(wall: Wall(nowMs: -5), entropy: Fill(byte: 1))
        #expect((try? ids.next()) == nil)
    }
}
