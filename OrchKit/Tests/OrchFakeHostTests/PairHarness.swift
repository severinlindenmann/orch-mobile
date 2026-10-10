import CryptoKit
import Foundation
import Testing
import OrchClient
import OrchCustody
import OrchFakeHost
import OrchProtocol
import OrchStore
@testable import OrchProtocol

/// A Demo phone in the pairing flow: an environment, a rig for one scenario, and a coordinator over the in-process relay. The test
/// plays the humans through explicit calls; nothing here approves anything.
struct PairHarness {
    let env: DemoEnvironment
    let clock: TestClock
    let vault: SecretVault
    let lock: SimulatedLock
    let custody: any DeviceKeyCustody
    let rig: PairingRig
    let config: PairingConfig
    let coordinator: PairingCoordinator
    var host: FakeHost { rig.host }
    var primary: FakePrimary { rig.primary }
    var relay: FakeRelay { env.relay }

    static func make(_ scenario: PairingScenario, faults: any FaultPolicy = NoFaults(), limits: RelayLimits = RelayLimits(),
                     clientHosted: Bool = false, hostedBy: String? = nil, name: String = "Laptop",
                     entropy: any Entropy = SystemEntropy(), phoneSkewMs: Int64 = 0) async throws -> PairHarness {
        let clock = TestClock()
        let lock = SimulatedLock()
        let vault = SecretVault(group: .keys, backend: InMemoryVaultBackend(lock: lock))
        let custody = DefaultCustody.make(vault: vault)
        let env = try await DemoSetup.setup(layout: tempLayout(), custody: custody, clock: clock, wall: clock, entropy: entropy, faults: faults, limits: limits)
        let rig = try await PairingRig.make(env: env, scenario: scenario, name: name, clientHosted: clientHosted, hostedBy: hostedBy)
        let config = PairingConfig(context: env.context, transport: env.transport, index: env.index, vault: vault, custody: custody, clock: clock,
                                   wall: SkewedWall(base: clock, skewMs: phoneSkewMs), entropy: entropy, deviceLabel: "Severin's iPhone")
        return PairHarness(env: env, clock: clock, vault: vault, lock: lock, custody: custody, rig: rig, config: config, coordinator: PairingCoordinator(config))
    }

    func link(_ offer: PairingOffer) throws -> PairingLink { try PairingLink.parse(offer.link) }

    /// Fakes act, the phone polls, a second passes. Stops when `until` holds (or after `steps`).
    @discardableResult
    func drive(steps: Int = 400, stepMs: Int64 = 1000, until: @Sendable (PairingState) -> Bool) async throws -> PairingState {
        for _ in 0..<steps {
            let s = await coordinator.state
            if until(s) { return s }
            try await rig.pump()
            await coordinator.poll()
            clock.advance(milliseconds: stepMs)
        }
        let s = await coordinator.state
        if until(s) { return s }
        return s
    }

    func relayHasNothing(for device: ID16) async -> Bool {
        let ws = host.workspace
        let grants = await relay.grantCount(workspace: ws, device: device)
        let wrap = await relay.hasCardKeyWrap(workspace: ws, device: device, cardSeq: 1)
        let wraps = await relay.cardKeyWrapCount(workspace: ws)
        let cert = await relay.hasCertificate(device)
        _ = wraps
        return grants == 0 && !wrap && !cert
    }

    /// No grant and no card-key wrap for `device` at any epoch or sequence, wherever the relay keeps them. The relay's whole wrap count
    /// is compared with the primary's own (the only legitimate holder at this point).
    func noKeyMaterial(for device: ID16, otherWraps: Int = 1) async -> Bool {
        let ws = host.workspace
        let grants = await relay.grantCount(workspace: ws, device: device)
        var wrap = false
        for seq in 1...3 as ClosedRange<UInt32> { if await relay.hasCardKeyWrap(workspace: ws, device: device, cardSeq: seq) { wrap = true } }
        let total = await relay.cardKeyWrapCount(workspace: ws)
        return grants == 0 && !wrap && total == otherWraps
    }

    /// No key material and no certificate for the device at the relay.
    func nothingFor(_ device: ID16) async -> Bool {
        let none = await noKeyMaterial(for: device)
        let cert = await relay.hasCertificate(device)
        return none && !cert
    }

    var phoneID: ID16 { env.deviceID }
}

func isComparingHost(_ s: PairingState) -> Bool { if case .comparingHost = s { return true }; return false }
func isWaitingPrimary(_ s: PairingState) -> Bool { if case .waitingPrimary = s { return true }; return false }
func isComparingPrimary(_ s: PairingState) -> Bool { if case .comparingPrimary = s { return true }; return false }
func isReady(_ s: PairingState) -> Bool { if case .ready = s { return true }; return false }
func isAlarm(_ s: PairingState) -> Bool { if case .alarm = s { return true }; return false }

/// The phone's own wall clock, running `skewMs` ahead of the Demo's (the host, the relay and the primary).
struct SkewedWall: WallClock {
    let base: TestClock
    let skewMs: Int64
    var nowMs: Int64 { base.nowMs + skewMs }
}
