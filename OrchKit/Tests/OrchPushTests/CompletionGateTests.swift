import Foundation
import Testing
@testable import OrchPush

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func record(_ v: Int) { lock.lock(); values.append(v); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
}

@Suite struct CompletionGateTests {
    @Test func finishThenFinishCallsOnce() {
        let gate = CompletionGate { 7 }
        let calls = Counter()
        gate.install { calls.record($0) }
        gate.finish()
        gate.finish()
        #expect(calls.count == 1)
    }

    @Test func expireThenInstallDelivers() {
        let gate = CompletionGate { 7 }
        let calls = Counter()
        gate.finish(expiring: true)
        #expect(calls.count == 0)
        gate.install { calls.record($0) }
        #expect(calls.count == 1)
    }

    @Test func installFinishExpireCallsOnce() {
        let gate = CompletionGate { 7 }
        let calls = Counter()
        gate.install { calls.record($0) }
        gate.finish()
        gate.finish(expiring: true)
        #expect(calls.count == 1)
    }

    @Test func concurrentFinishAndExpireCallsOnce() {
        for _ in 0..<200 {
            let gate = CompletionGate { 7 }
            let calls = Counter()
            gate.install { calls.record($0) }
            DispatchQueue.concurrentPerform(iterations: 2) { i in
                gate.finish(expiring: i == 1)
            }
            #expect(calls.count == 1)
        }
    }
}
