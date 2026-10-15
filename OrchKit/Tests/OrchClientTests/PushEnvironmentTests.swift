import Foundation
import Testing
@testable import OrchClient

@Suite struct PushEnvironmentTests {
    /// A CMS-like blob: binary noise around the XML plist, as `embedded.mobileprovision` has it.
    private func profile(aps: String?) -> Data {
        var ent = ""
        if let aps { ent = "<key>aps-environment</key><string>\(aps)</string>" }
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>Name</key><string>x</string><key>Entitlements</key><dict>\(ent)<key>get-task-allow</key><true/></dict></dict></plist>"
        return Data([0x30, 0x82, 0x01, 0x00, 0xff]) + Data(xml.utf8) + Data([0x00, 0x31, 0xfe])
    }

    @Test func developmentProfileIsSandboxProductionProfileIsProduction() {
        #expect(PushEnvironment.resolve(provisioningProfile: profile(aps: "development"), isSimulator: false) == .sandbox)
        #expect(PushEnvironment.resolve(provisioningProfile: profile(aps: "production"), isSimulator: false) == .production)
    }

    @Test func noProfileOnADeviceIsTestFlightOrAppStoreSoProduction() {
        #expect(PushEnvironment.resolve(provisioningProfile: nil, isSimulator: false) == .production)
    }

    @Test func theSimulatorNeverRegistersWhateverTheProfileSays() {
        #expect(PushEnvironment.resolve(provisioningProfile: nil, isSimulator: true) == nil)
        #expect(PushEnvironment.resolve(provisioningProfile: profile(aps: "development"), isSimulator: true) == nil)
    }

    @Test func aProfileWithoutAUsablePushEntitlementDoesNotRegister() {
        #expect(PushEnvironment.resolve(provisioningProfile: profile(aps: nil), isSimulator: false) == nil)
        #expect(PushEnvironment.resolve(provisioningProfile: profile(aps: "staging"), isSimulator: false) == nil)
        #expect(PushEnvironment.resolve(provisioningProfile: Data("garbage".utf8), isSimulator: false) == nil)
    }

    @Test func anUnreadableProfileFileIsUnknownNotProduction() {
        #expect(PushEnvironment.resolve(profile: .unreadable, isSimulator: false) == nil)
        #expect(PushEnvironment.resolve(profile: .absent, isSimulator: false) == .production)
        #expect(PushEnvironment.resolve(profile: .data(profile(aps: "development")), isSimulator: false) == .sandbox)
    }
}
