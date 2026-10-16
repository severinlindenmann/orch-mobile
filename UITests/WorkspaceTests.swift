import XCTest

final class WorkspaceTests: XCTestCase {
    @MainActor
    func testSegmentsOnLaptop() {
        let app = launch("workspace/laptop")
        XCTAssertTrue(app.el("ws.segment.questions").waitForExistence(timeout: 90))
        XCTAssertTrue(app.questionRow("Enable mobile access?").waitForExistence(timeout: 30))
        app.el("ws.segment.tickets").tap()
        XCTAssertTrue(app.el("ticket.FAC-0001").waitForExistence(timeout: 10))
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
        let app = launch("ticket/laptop/FAC-0001")
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

    /// The form: type and a one-line title; a violation is shown inline and blocks Review.
    @MainActor
    private func openNewTicket(_ app: XCUIApplication) -> XCUIElement {
        let add = app.buttons["ws.newTicket"]
        XCTAssertTrue(add.waitForExistence(timeout: 90))
        add.tap()
        let title = app.textFields["ticket.new.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        return title
    }

    @MainActor
    func testNewTicketIsReviewedSignedAndCreatedOnce() {
        let app = launch("workspace/laptop/tickets")
        let title = openNewTicket(app)
        title.tap(); title.typeText("Check the Demo ticket")
        XCTAssertFalse(app.el("ticket.new.titleError").exists)
        app.buttons["ticket.new.review"].tap()
        // the creation sheet: type, title, owner and the key disclosure; Sign armed only after the end and the delay
        let disclosure = app.el("create.disclosure")
        XCTAssertTrue(disclosure.waitForExistence(timeout: 60))
        XCTAssertTrue(disclosure.label.contains("The key is assigned when sent (next: "), disclosure.label)
        XCTAssertTrue(app.el("create.type").label.contains("Feature"))
        XCTAssertTrue(app.el("create.title").label.contains("Check the Demo ticket"))
        XCTAssertTrue(app.el("create.owner").label.contains("You"))
        let confirm = app.buttons["create.confirm"]
        XCTAssertTrue(confirm.exists)
        XCTAssertTrue(app.arm(confirm))
        confirm.tap()
        let created = app.el("create.created")
        XCTAssertTrue(created.waitForExistence(timeout: 60))
        app.buttons["create.done"].tap()
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'ticket.' AND label CONTAINS 'Check the Demo ticket'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30))
        XCTAssertEqual(rows.count, 1)
    }

    @MainActor
    func testAKeyRaceIsSentAgainWithTheNextKey() {
        let app = launch("workspace/laptop/tickets", extra: ["--demo-key-race"])
        let title = openNewTicket(app)
        title.tap(); title.typeText("Raced ticket")
        app.buttons["ticket.new.review"].tap()
        let disclosure = app.el("create.disclosure")
        XCTAssertTrue(disclosure.waitForExistence(timeout: 60))
        let confirm = app.buttons["create.confirm"]
        XCTAssertTrue(app.arm(confirm))
        confirm.tap()
        let resent = app.el("create.resent")
        XCTAssertTrue(resent.waitForExistence(timeout: 60))
        XCTAssertTrue(resent.label.contains("The workspace changed; sent again"), resent.label)
    }

    /// A signed creation that is still being checked, reopened from the form (the relaunch path: the draft says "pending"), then settled
    /// with "Check again": the form shows the result, never the signed title with Review again (a second signature, a duplicate).
    @MainActor
    func testACreationSettledFromTheFormShowsTheResultNotReviewAgain() {
        let app = launch("workspace/laptop/tickets", extra: ["--demo-hold-creation"])
        let title = openNewTicket(app)
        title.tap(); title.typeText("Held ticket")
        app.buttons["ticket.new.review"].tap()
        let confirm = app.buttons["create.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 60))
        XCTAssertTrue(app.arm(confirm))
        confirm.tap()
        let close = app.buttons["create.closeChecking"]
        XCTAssertTrue(close.waitForExistence(timeout: 60), "the held creation stays checking")
        close.tap()
        let add = app.buttons["ws.newTicket"]
        XCTAssertTrue(add.waitForExistence(timeout: 30))
        add.tap()
        XCTAssertTrue(app.el("ticket.new.checking").waitForExistence(timeout: 10))
        app.buttons["ticket.new.recheck"].tap()
        let created = app.el("create.created")
        XCTAssertTrue(created.waitForExistence(timeout: 60), "the settled result is shown in the form")
        XCTAssertFalse(app.buttons["ticket.new.review"].exists, "no Review for a settled creation")
        XCTAssertFalse(app.textFields["ticket.new.title"].exists)
        // a new ticket is started explicitly, and starts empty
        app.buttons["ticket.new.another"].tap()
        let fresh = app.textFields["ticket.new.title"]
        XCTAssertTrue(fresh.waitForExistence(timeout: 10))
        XCTAssertFalse((fresh.value as? String ?? "").contains("Held ticket"), "the signed title is not prefilled")
        XCTAssertFalse(app.buttons["ticket.new.review"].isEnabled)
        app.buttons["ticket.new.cancel"].tap()
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'ticket.' AND label CONTAINS 'Held ticket'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30))
        XCTAssertEqual(rows.count, 1)
    }

    @MainActor
    func testATitleViolationIsShownInlineAndBlocksReview() {
        let app = launch("workspace/laptop/tickets")
        let title = openNewTicket(app)
        title.tap(); title.typeText(String(repeating: "x", count: 201))
        let problem = app.el("ticket.new.titleError")
        XCTAssertTrue(problem.waitForExistence(timeout: 10))
        XCTAssertTrue(problem.label.contains("At most 200 characters"), problem.label)
        XCTAssertFalse(app.buttons["ticket.new.review"].isEnabled)
        XCTAssertFalse(app.el("ticket.new.body").exists, "no Details field (R2 is title-only)")
    }

    /// Creating needs `decide` (and the host's support), not `operate`: the Client VM workspace (look, decide) offers it.
    @MainActor
    func testNewTicketNeedsDecideNotOperate() {
        let app = launch("workspace/client-vm/tickets")
        XCTAssertTrue(app.el("ws.segment.questions").waitForExistence(timeout: 90))
        XCTAssertTrue(app.buttons["ws.newTicket"].waitForExistence(timeout: 30))
    }
}
