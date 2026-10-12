import XCTest

final class WorkspaceTests: XCTestCase {
    @MainActor
    func testSegmentsOnLaptop() {
        let app = launch("workspace/laptop")
        XCTAssertTrue(app.el("ws.segment.questions").waitForExistence(timeout: 90))
        XCTAssertTrue(app.questionRow("Enable mobile access?").waitForExistence(timeout: 30))
        app.el("ws.segment.tickets").tap()
        XCTAssertTrue(app.el("ticket.FAC-1").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["1 of 3 done"].waitForExistence(timeout: 10))
        app.el("ws.segment.files").tap()
        XCTAssertTrue(app.el("ws.file.d-readme").waitForExistence(timeout: 30), "this workspace's verified Drop items")
        XCTAssertFalse(app.el("ws.file.d-deploy").exists, "other workspace's items are not listed")
        XCTAssertTrue(app.el("ws.files.openDrop").exists)
        app.el("ws.segment.terminal").tap()
        XCTAssertTrue(app.el("ws.terminal.later").waitForExistence(timeout: 5))
    }

    @MainActor
    func testTerminalHiddenWhenScopeMissing() {
        let app = launch("workspace/client-vm")
        XCTAssertTrue(app.el("ws.segment.questions").waitForExistence(timeout: 90))
        XCTAssertFalse(app.el("ws.segment.terminal").exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Hosted by Example Client'")).firstMatch.exists)
    }

    @MainActor
    func testFactoryEpicDetail() {
        let app = launch("ticket/laptop/FAC-1")
        XCTAssertTrue(app.el("ticket.epicProgress").waitForExistence(timeout: 90))
    }

    @MainActor
    func testSegmentsCollapseToMenuAtAccessibilitySizes() {
        let app = launch("workspace/laptop", extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXL"])
        XCTAssertTrue(app.el("ws.segment.menu").waitForExistence(timeout: 90))
        XCTAssertFalse(app.buttons["ws.segment.tickets"].exists)
        let header = app.el("workspace.header")
        XCTAssertTrue(header.exists)
        XCTAssertTrue(header.label.contains("Laptop"), header.label)
    }

    @MainActor
    func testNewTicketIsCreatedOnTheHostOnce() {
        let app = launch("workspace/laptop/tickets")
        let add = app.buttons["ws.newTicket"]
        XCTAssertTrue(add.waitForExistence(timeout: 90))
        add.tap()
        let title = app.textFields["ticket.new.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap(); title.typeText("Check the Demo ticket")
        app.buttons["ticket.new.create"].tap()
        XCTAssertTrue(app.el("ticket.new.created").waitForExistence(timeout: 60))
        app.buttons["ticket.new.done"].tap()
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'ticket.' AND label CONTAINS 'Check the Demo ticket'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30))
        XCTAssertEqual(rows.count, 1)
    }

    @MainActor
    func testNewTicketHiddenWithoutOperateScope() {
        let app = launch("workspace/client-vm/tickets")
        XCTAssertTrue(app.el("ws.segment.questions").waitForExistence(timeout: 90))
        XCTAssertFalse(app.buttons["ws.newTicket"].exists)
    }
}
