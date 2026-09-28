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
        waitScreens(app, 3, "the stage has no screen 3")
        XCTAssertTrue(app.pagePosition.isHittable, "no dots on the stage")
        // The reply turns the stage to its last screen; start from the answer.
        let screen = { (n: Int) in app.descendants(matching: .any)["stage-screen-\(n)"] }
        XCTAssertTrue(screen(3).waitForExistence(timeout: 10), "the reply did not show screen 3")
        app.goToScreen(1)
        XCTAssertTrue(waitGone(screen(3)), "paging did not go back to the answer")
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

    /// The dots (YUI-187, Chris Sep 28: "the dots we removed ... i also want those to slide, not
    /// fade between them and the dots should animate"). A slow drag moves the page with the
    /// finger: short of a fifth of the screen it springs back, past it the next page lands where
    /// the finger took it. The dots say where you are, and a tap on one goes there.
    func testDotsFollowTheDrag() throws { try dots(reduceMotion: false) }

    /// Reduce Motion: the pages cross-fade instead of sliding, and the dots stay.
    func testDotsReduceMotion() throws { try dots(reduceMotion: true) }

    private func dots(reduceMotion: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "yui",
                               "-appearance", "light", "-yuiDemoReply", StagePagesTests.reply,
                               "-yuiDemoPickupAfter", "0.5", "-yuiDemoReplyAfter", "2"]
            + (reduceMotion ? ["-yuiReduceMotion"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["stage-type"].waitForExistence(timeout: 15), "no stage")
        app.buttons["stage-type"].tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Cooking bibimbap, keep me on track")
        app.buttons["stage-send-text"].tap()
        waitScreens(app, 3, "the stage has no screen 3")
        let screen = { (n: Int) in app.descendants(matching: .any)["stage-screen-\(n)"] }
        XCTAssertTrue(screen(3).waitForExistence(timeout: 10), "the reply did not show screen 3")
        let dots = app.pagePosition
        XCTAssertTrue(dots.isHittable, "no dots")
        XCTAssertEqual(dots.value as? String, "3 of 3", "the dots are not on screen 3")

        // A tap on the first dot goes home.
        tapDot(app, 0)
        waitScreen(app, 1, "the first dot did not go to the answer")
        XCTAssertEqual(dots.value as? String, "1 of 3")

        // A slow, short drag: the page goes with the finger and comes back.
        let mid = app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.45))
        mid.press(forDuration: 0.1, thenDragTo: mid.withOffset(CGVector(dx: -50, dy: 0)),
                  withVelocity: 60, thenHoldForDuration: 0.3)
        sleep(1)
        waitScreen(app, 1, "a short slow drag turned the page")

        // A slow, long drag: the next page lands, whole, where it belongs.
        mid.press(forDuration: 0.1, thenDragTo: mid.withOffset(CGVector(dx: -200, dy: 0)),
                  withVelocity: 150, thenHoldForDuration: 0.1)
        waitScreen(app, 2, "a long slow drag did not turn to screen 2")
        XCTAssertTrue(screen(2).waitForExistence(timeout: 3), "screen 2 is not on show")
        sleep(1)
        let two = screen(2).frame, stage = app.windows.firstMatch.frame
        XCTAssertLessThan(abs(two.midX - stage.midX), 30, "screen 2 did not settle in the middle (\(two))")
        XCTAssertFalse(screen(3).exists, "the page beside it is still drawn")
        XCTAssertEqual(dots.value as? String, "2 of 3", "the dots did not follow")
        shot("dots-\(reduceMotion ? "still" : "slide")-screen2")

        // The third dot jumps.
        tapDot(app, 2)
        waitScreen(app, 3, "the third dot did not go to screen 3")
        XCTAssertEqual(dots.value as? String, "3 of 3")
        sleep(1)
        shot("dots-\(reduceMotion ? "still" : "slide")-screen3")

        // The drag back comes the other way.
        app.swipeRight()
        waitScreen(app, 2, "a drag right on screen 3 did not go back to screen 2")
    }

    /// Taps dot `k` (0 is the first) inside the dots' row: 8 points of padding, then a dot
    /// every `PageDots.pitch` (14) from the pill's half width (8).
    private func tapDot(_ app: XCUIApplication, _ k: Int) {
        let row = app.pagePosition
        let x = 8 + 8 + CGFloat(k) * 14
        row.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: row.frame.height / 2)).tap()
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
