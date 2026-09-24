import XCTest

/// The way back down a long thread (YUI-50): scrolled up more than about a
/// screen, a round arrow shows over the composer, counts the agent's messages
/// that land meanwhile, and one tap brings the newest back. Demo account, no
/// network. `TEST_RUNNER_YUI_SHOTS=<dir>` saves screenshots.
final class JumpToBottomTests: XCTestCase {
    private func launch(_ appearance: String, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiLongThread", "40", "-appearance", appearance] + extra
        app.launch()
        return app
    }

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
    }

    private func arrow(_ app: XCUIApplication) -> XCUIElement { app.buttons["jump-to-bottom"] }

    private func gone(_ e: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let end = Date.now.addingTimeInterval(timeout)
        while e.exists, Date.now < end { usleep(100_000) }
        return !e.exists
    }

    /// Scroll well up: more than a screen above the newest message.
    private func scrollUp(_ app: XCUIApplication) {
        let thread = app.scrollViews.firstMatch
        for _ in 0..<3 { thread.swipeDown(velocity: .slow) }
    }

    private func newest(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Message 40.")).firstMatch
    }

    func testArrowShowsCountsAndJumps() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance, ["-yuiIncomingWhenUp", "3"])
            XCTAssertTrue(app.descendants(matching: .any)["composer"].firstMatch.waitForExistence(timeout: 20), "no composer")
            XCTAssertTrue(newest(app).waitForExistence(timeout: 5), "the thread did not open at the newest message")
            XCTAssertFalse(arrow(app).exists, "the arrow shows at the bottom")

            // A small scroll is not enough.
            app.scrollViews.firstMatch.swipeDown(velocity: 300)
            sleep(1)
            XCTAssertFalse(arrow(app).exists, "the arrow shows a few lines up")

            scrollUp(app)
            XCTAssertTrue(arrow(app).waitForExistence(timeout: 5), "no arrow after scrolling well up")
            shot("jump-01-arrow-\(appearance)")

            // Three agent messages land while up there: the arrow counts them.
            let counted = NSPredicate(format: "value == %@", "3 new")
            let wait = expectation(for: counted, evaluatedWith: arrow(app))
            self.wait(for: [wait], timeout: 10)
            XCTAssertTrue(arrow(app).isHittable)
            sleep(1)
            shot("jump-02-arrow-badge-\(appearance)")

            arrow(app).tap()
            let last = app.staticTexts["While you were up there, note 3 of 3."]
            XCTAssertTrue(last.waitForExistence(timeout: 5), "the newest message never arrived")
            sleep(1)
            XCTAssertTrue(last.isHittable, "the tap did not bring the newest message into view")
            XCTAssertTrue(gone(arrow(app)), "the arrow stays at the bottom")
            shot("jump-03-back-at-bottom-\(appearance)")

            // Up again: the count started over.
            scrollUp(app)
            XCTAssertTrue(arrow(app).waitForExistence(timeout: 5))
            XCTAssertEqual(arrow(app).value as? String ?? "", "", "the count survived the trip to the bottom")
            app.terminate()
        }
    }

    /// Scrolling back down by hand hides it too.
    func testArrowHidesWhenScrolledBackDown() {
        let app = launch("light")
        XCTAssertTrue(newest(app).waitForExistence(timeout: 20))
        scrollUp(app)
        XCTAssertTrue(arrow(app).waitForExistence(timeout: 5))
        XCTAssertEqual(arrow(app).value as? String ?? "", "", "a count with nothing new")
        for _ in 0..<6 { app.scrollViews.firstMatch.swipeUp(velocity: .fast) }
        XCTAssertTrue(gone(arrow(app)), "the arrow stays after scrolling back to the bottom")
    }

    /// Sending from up the thread brings you down to your message.
    func testSendingFromUpTheThreadJumps() {
        let app = launch("light")
        let field = app.descendants(matching: .any)["composer"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        scrollUp(app)
        XCTAssertTrue(arrow(app).waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Back to the bottom please")
        app.buttons["Send"].tap()
        let sent = app.staticTexts["Back to the bottom please"]
        XCTAssertTrue(sent.waitForExistence(timeout: 5))
        sleep(1)
        XCTAssertTrue(sent.isHittable, "your sent message is off screen")
        XCTAssertTrue(gone(arrow(app)), "the arrow stays after sending")
    }
}
