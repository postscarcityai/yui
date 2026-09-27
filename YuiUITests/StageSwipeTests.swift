import XCTest

/// Sideways on the full screen, like before the stage (Chris, TestFlight AC0r0OFGJiJOcbFdbXMgHms:
/// "we lost the left and right scroll functionality ... when I scroll with my thumb towards the
/// right, I wanna pull the drawer out to the left. When I dragged my thumb from the right or
/// left, I want to show the other screens"). On the stage a drag left shows the next screen and
/// a drag right the one before; on the answer a drag right pulls the drawer out. On the chat a
/// drag left opens the stage on the first screen. The bar (+, T, mic) is on every screen.
/// Demo account, no network. Screenshots go to `YUI_SHOTS` when set.
final class StageSwipeTests: XCTestCase {
    func testLight() throws { try run("light") }
    func testDark() throws { try run("dark") }

    /// The empty stage in the screenshot (Basil, nothing asked yet): a drag right opens the drawer.
    func testDrawerFromTheGreeting() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "yui",
                               "-appearance", "dark"]
        app.launch()
        XCTAssertTrue(app.buttons["stage-type"].waitForExistence(timeout: 15), "no stage")
        app.swipeRight()
        XCTAssertTrue(app.buttons["drawer-close"].waitForExistence(timeout: 5), "a drag right on the greeting did not open the drawer")
        shot("swipe-greeting-drawer-dark")
    }

    private func run(_ appearance: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "yui",
                               "-appearance", appearance, "-yuiDemoReply", StagePagesTests.reply,
                               "-yuiDemoPickupAfter", "0.5", "-yuiDemoReplyAfter", "2"]
        app.launch()
        XCTAssertTrue(app.buttons["stage-type"].waitForExistence(timeout: 15), "no stage")
        app.buttons["stage-type"].tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Cooking bibimbap, keep me on track")
        app.buttons["stage-send-text"].tap()
        XCTAssertTrue(app.buttons["page-tab-3"].waitForExistence(timeout: 20), "no screen dots on the stage")
        // The reply turns the stage to its last screen; start from the answer.
        let screen = { (n: Int) in app.descendants(matching: .any)["stage-screen-\(n)"] }
        XCTAssertTrue(screen(3).waitForExistence(timeout: 10), "the reply did not show screen 3")
        app.buttons["page-tab-1"].tap()
        XCTAssertTrue(waitGone(screen(3)), "the Answer dot did not go back to the answer")
        sleep(1)
        func bar(_ where_: String) {
            XCTAssertTrue(app.buttons["stage-type"].exists, "no T on \(where_)")
            XCTAssertTrue(app.buttons["stage-attach"].exists || app.buttons["stage-mic"].exists, "no + or mic on \(where_)")
        }

        // Left: the answer, then screen 2, then screen 3.
        app.swipeLeft()
        XCTAssertTrue(screen(2).waitForExistence(timeout: 5), "a drag left on the answer did not show screen 2")
        bar("screen 2")
        shot("swipe-\(appearance)-screen2")
        app.swipeLeft()
        XCTAssertTrue(screen(3).waitForExistence(timeout: 5), "a drag left on screen 2 did not show screen 3")
        bar("screen 3")
        shot("swipe-\(appearance)-screen3")

        // Right: back one screen at a time, and no drawer on the way.
        app.swipeRight()
        XCTAssertTrue(screen(2).waitForExistence(timeout: 5), "a drag right on screen 3 did not go back to screen 2")
        XCTAssertFalse(app.buttons["drawer-close"].exists, "the drawer opened from screen 3")
        app.swipeRight()
        XCTAssertTrue(waitGone(screen(2)), "a drag right on screen 2 did not go back to the answer")
        XCTAssertFalse(app.buttons["drawer-close"].exists, "the drawer opened from screen 2")
        bar("the answer")

        // On the answer a drag right pulls the drawer out.
        app.swipeRight()
        let close = app.buttons["drawer-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "a drag right on the answer did not open the drawer")
        sleep(1)
        shot("swipe-\(appearance)-drawer")
        close.tap()
        XCTAssertTrue(waitGone(close), "the drawer did not close")

        // The chat: a drag left opens the stage on screen 2.
        app.buttons["stage-record"].tap()
        XCTAssertTrue(app.buttons["back-to-stage"].waitForExistence(timeout: 10), "the chat did not open")
        sleep(1)
        app.swipeLeft()
        XCTAssertTrue(screen(2).waitForExistence(timeout: 5), "a drag left on the chat did not open screen 2 on the stage")
        bar("screen 2 from the chat")
    }

    private func waitGone(_ e: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if !e.exists { return true }; usleep(200_000) }
        return !e.exists
    }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
