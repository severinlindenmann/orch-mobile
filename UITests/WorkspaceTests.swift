import XCTest

final class WorkspaceTests: XCTestCase {
    @MainActor
    func testSegmentsOnLaptop() {
        let app = launch("workspace/laptop")
        XCTAssertTrue(app.el("ws.segment.questions").waitForExistence(timeout: 10))
        XCTAssertTrue(app.el("question.q1").exists)
        app.el("ws.segment.tickets").tap()
        XCTAssertTrue(app.el("ticket.FAC-1").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 of 3 done"].exists)
        app.el("ws.segment.files").tap()
        XCTAssertTrue(app.el("ws.file.d-readme").waitForExistence(timeout: 5), "this workspace's Drop items")
        XCTAssertFalse(app.el("ws.file.d-deploy").exists, "other workspace's items are not listed")
        XCTAssertTrue(app.el("ws.files.openDrop").exists)
        app.el("ws.segment.terminal").tap()
        XCTAssertTrue(app.el("ws.terminal.later").waitForExistence(timeout: 5))
    }

    @MainActor
    func testTerminalHiddenWhenScopeMissing() {
        let app = launch("workspace/client-vm")
        XCTAssertTrue(app.el("ws.segment.questions").waitForExistence(timeout: 10))
        XCTAssertFalse(app.el("ws.segment.terminal").exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Hosted by Example Client'")).firstMatch.exists)
    }

    @MainActor
    func testFactoryEpicDetail() {
        let app = launch("ticket/laptop/FAC-1")
        XCTAssertTrue(app.el("ticket.epicProgress").waitForExistence(timeout: 10))
    }

    @MainActor
    func testSegmentsCollapseToMenuAtAccessibilitySizes() {
        let app = launch("workspace/laptop", extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXL"])
        XCTAssertTrue(app.el("ws.segment.menu").waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["ws.segment.tickets"].exists)
        let header = app.el("workspace.header")
        XCTAssertTrue(header.exists)
        XCTAssertTrue(header.label.contains("Laptop"), header.label)
    }
}
