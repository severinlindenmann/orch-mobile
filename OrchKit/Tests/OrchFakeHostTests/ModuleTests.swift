import Testing
@testable import OrchFakeHost

@Test func moduleIsAvailable() {
    #expect(OrchFakeHostModule.name == "OrchFakeHost")
}
