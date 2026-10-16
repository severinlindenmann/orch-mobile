import CryptoKit
import Foundation
import Testing
@testable import OrchClient
@testable import OrchFakeHost
import OrchCustody
import OrchProtocol
import OrchStore

private func tokenB64(_ n: UInt8, count: Int = 32) -> String { B64U.encode(Data(repeating: n, count: count)) }

@Suite struct PushServiceTests {
    private func setup(push: Bool = true) async throws -> (World, Phone, PushService) {
        let w = try await World.drop()
        await w.relay.setPushEnabled(push)
        let phone = try await w.makePhone()
        return (w, phone, PushService(session: phone.session))
    }

    @Test func anUnreadableUnregisterReplyIsOwedNotDone() {
        #expect(PushService.unregisterOutcome(of: ClientError.badReply) == .failed("bad_reply"))
        #expect(PushService.outcome(of: ClientError.badReply) == .refused("bad_reply"))
    }

    @Test func pushOffRelayAnswers404AndPersistsNothingConfirmed() async throws {
        let (w, phone, service) = try await setup(push: false)
        #expect(await service.register(token: tokenB64(1), env: .sandbox) == .pushOff)
        #expect(await w.relay.pushRegistrationCount == 0)
        let row = try await phone.container.pushRegistration(env: "sandbox")
        #expect(row?.confirmedMs == nil)
        #expect(await service.unregisterAll() == .pushOff)
    }

    @Test func registerSendsTheSpecBodyAndIsIdempotent() async throws {
        let (w, phone, service) = try await setup()
        guard case .registered(let id) = await service.register(token: tokenB64(2), env: .sandbox) else { Issue.record("not registered"); return }
        let regs = await w.relay.pushRegistrations(device: w.phoneID)
        #expect(regs.count == 1 && regs[0].id == id && regs[0].env == "sandbox" && regs[0].workspace == w.ws && regs[0].token == tokenB64(2))
        // every launch: same body, same id, no second registration
        #expect(await service.register(token: tokenB64(2), env: .sandbox) == .registered(id))
        let count = await w.relay.pushRegistrationCount, requests = await w.relay.pushRegisterRequests
        #expect(count == 1 && requests == 2)
        let row = try await phone.container.pushRegistration(env: "sandbox")
        #expect(row?.registrationID == id.hex && row?.confirmedMs != nil)
    }

    @Test func aChangedTokenMintsANewIdAndRetiresTheOld() async throws {
        let (w, _, service) = try await setup()
        guard case .registered(let first) = await service.register(token: tokenB64(3), env: .production) else { Issue.record("a"); return }
        guard case .registered(let second) = await service.register(token: tokenB64(4), env: .production) else { Issue.record("b"); return }
        #expect(first != second)
        let regs = await w.relay.pushRegistrations(device: w.phoneID)
        #expect(regs.count == 1 && regs[0].id == second && regs[0].token == tokenB64(4))
        // the old id is unregistered explicitly (not `null`: that would remove the new one too)
        #expect(await w.relay.pushUnregisteredIDs == [first])
    }

    @Test func aFailedRegisterAfterATokenChangeStillUnregistersTheOldIdNextTime() async throws {
        let (w, phone, service) = try await setup()
        guard case .registered(let first) = await service.register(token: tokenB64(3), env: .production) else { Issue.record("a"); return }
        await w.relay.scriptPush([w.relay.refuse(429, .rateLimited)])
        #expect(await service.register(token: tokenB64(4), env: .production) == .rateLimited(retryAfter: nil))
        let owedRow = try #require(try await phone.container.pushRegistration(env: "production"))
        #expect(owedRow.supersedes == first.hex && owedRow.confirmedMs == nil)
        #expect(await w.relay.pushUnregisteredIDs.isEmpty)
        // the next launch: same token, same new id, and now the old id is unregistered
        guard case .registered(let second) = await service.register(token: tokenB64(4), env: .production) else { Issue.record("b"); return }
        #expect(second.hex == owedRow.registrationID)
        #expect(await w.relay.pushUnregisteredIDs == [first])
        #expect(try await phone.container.pushRegistration(env: "production")?.supersedes == nil)
    }

    @Test func registrationConflictMintsOneNewIdAndRetriesOnce() async throws {
        let (w, _, service) = try await setup()
        guard case .registered(let first) = await service.register(token: tokenB64(5), env: .sandbox) else { Issue.record("a"); return }
        await w.relay.scriptPush([w.relay.refuse(409, .registrationConflict)])
        guard case .registered(let second) = await service.register(token: tokenB64(5), env: .sandbox) else { Issue.record("b"); return }
        #expect(first != second)
        #expect(await w.relay.pushRegistrations(device: w.phoneID).map(\.id) == [second])
        // a second conflict in a row is reported, not looped
        await w.relay.scriptPush([w.relay.refuse(409, .registrationConflict), w.relay.refuse(409, .registrationConflict)])
        #expect(await service.register(token: tokenB64(5), env: .sandbox) == .failed("registration_conflict"))
    }

    @Test func refusalsMapToOutcomes() async throws {
        let (w, _, service) = try await setup()
        await w.relay.scriptPush([w.relay.refuse(403, .notEligible)])
        #expect(await service.register(token: tokenB64(6), env: .sandbox) == .refused("not_eligible"))
        await w.relay.scriptPush([w.relay.refuse(403, .revoked)])
        #expect(await service.register(token: tokenB64(6), env: .sandbox) == .refused("revoked"))
        await w.relay.scriptPush([w.relay.refuse(429, .rateLimited, headers: ["retry-after": "30"])])
        #expect(await service.register(token: tokenB64(6), env: .sandbox) == .rateLimited(retryAfter: 30))
    }

    @Test func invalidTokensNeverReachTheRelay() async throws {
        let (w, _, service) = try await setup()
        let short = await service.register(token: tokenB64(7, count: 31), env: .sandbox)
        let long = await service.register(token: tokenB64(7, count: 101), env: .sandbox)
        #expect(short == .refused("invalid_argument") && long == .refused("invalid_argument"))
        let requests = await w.relay.pushRegisterRequests
        #expect(requests == 0)
    }

    @Test func unregisterAllRemovesRegistrationsAndClearsTheLocalRecord() async throws {
        let (w, phone, service) = try await setup()
        _ = await service.register(token: tokenB64(8), env: .sandbox)
        _ = await service.register(token: tokenB64(9), env: .production)
        #expect(await w.relay.pushRegistrationCount == 2)
        #expect(await service.unregisterAll() == .removed)
        #expect(await w.relay.pushRegistrationCount == 0)
        #expect(try await phone.container.pushRegistration(env: "sandbox") == nil)
        #expect(await service.unregisterAll() == .removed)         // idempotent
    }

    @Test func detachedUnregisterNeedsOnlyTheDeviceKey() async throws {
        let (w, _, service) = try await setup()
        _ = await service.register(token: tokenB64(10), env: .sandbox)
        let outcome = await PushService.unregisterAll(workspace: w.ws, identity: w.env.device, transport: w.transport)
        #expect(outcome == .removed)
        #expect(await w.relay.pushRegistrationCount == 0)
    }

    @Test func keyMaterialIsKPushOfTheHeldEpochsAndNeverTheWK() async throws {
        let (w, _, service) = try await setup()
        let m = try await service.keyMaterial()
        let wk = try #require(await w.host.wks[1])
        let expected = KDF.kPush(wk: wk, workspace: w.ws, epoch: 1).withUnsafeBytes { Data($0) }
        #expect(m.kPush[1] == expected && m.kPush[1] != wk.withUnsafeBytes { Data($0) })
        #expect(m.wsk.x963 == w.host.wskPublic.x963)
    }

    @Test func theEpochObserverFiresOnlyWhenTheEpochRises() async throws {
        let (w, phone, _) = try await setup()
        let seen = Box<[UInt32]>([])
        await phone.session.setEpochObserver { e in seen.mutate { $0.append(e) } }
        try await phone.session.install(epoch: 1, key: #require(await w.host.wks[1]))
        #expect(seen.value.isEmpty)
        try await phone.session.install(epoch: 2, key: SymmetricKey(size: .bits256))
        #expect(seen.value == [2])
    }
}

private final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.withLock { v } }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&v) } }
}
