import Testing
@testable import OrchClient

@Test func moduleIsAvailable() {
    #expect(OrchClientModule.name == "OrchClient")
}
