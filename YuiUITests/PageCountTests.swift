import XCTest

/// As many screens as the agent uses, up to 12 (TestFlight feedback on build 57):
/// the pager has the chat plus one page per screen with something on it, and the
/// indicator above the composer is a chat glyph and one dot per screen. With only
/// the chat there is no indicator at all; `>13` stays in the chat; `>N clear`
/// takes the page away. Demo account, no network. Screenshots go to `YUI_SHOTS`.
final class PageCountTests: XCTestCase {
    /// Chat only: a reply with nothing routed to a screen.
    func testChatOnlyHasNoIndicator() throws {
        let app = launch("one", ["say Just the chat today.", "ask \"Start?\""])
        XCTAssertTrue(app.staticTexts["Just the chat today."].waitForExistence(timeout: 15), "the reply never came")
        sleep(1)
        XCTAssertFalse(app.otherElements["page-tabs"].exists, "an indicator with only the chat")
        XCTAssertFalse(app.buttons["page-tab-1"].exists, "a chat tab with only the chat")
        shot(app, "1-chat-only")
    }

    /// Two pages: the chat glyph and one dot.
    func testTwoScreens() throws {
        let app = launch("two", ["say One screen.", ">2 list Today Squat|Bench +check"])
        try expectTabs(app, count: 2)
        shot(app, "2-screens")
        app.buttons["page-tab-1"].tap()
        waitSelected(app.buttons["page-tab-1"], "the chat glyph does not go to the chat")
        shot(app, "2-screens-chat")
    }

    /// Five pages, numbered as sent.
    func testFiveScreens() throws {
        let app = launch("five", ["say Four screens."] + (2...5).map { ">\($0) say Screen \($0) note" })
        try expectTabs(app, count: 5)
        shot(app, "5-screens")
        app.buttons["page-tab-3"].tap()
        let three = app.descendants(matching: .any)["page-3"].staticTexts["Screen 3 note"]
        waitHittable(three, "the third dot does not go to screen 3")
        waitSelected(app.buttons["page-tab-3"], "the third dot is not selected")
        shot(app, "5-screens-on-3")
    }

    /// Twelve pages, the most; `>13` has no page and stays in the chat.
    func testTwelveScreensAndNoThirteenth() throws {
        let app = launch("twelve", ["say Eleven screens."] + (2...12).map { ">\($0) say Screen \($0) note" } + [">13 say Thirteen stays in the chat"])
        try expectTabs(app, count: 12)
        XCTAssertFalse(app.buttons["page-tab-13"].exists, "a thirteenth screen")
        XCTAssertFalse(app.descendants(matching: .any)["page-13"].exists, "a page for screen 13")
        app.buttons["page-tab-1"].tap()
        waitHittable(app.staticTexts["Thirteen stays in the chat"], ">13 did not land in the chat")
        shot(app, "12-screens")
        app.buttons["page-tab-12"].tap()
        waitHittable(app.descendants(matching: .any)["page-12"].staticTexts["Screen 12 note"], "the last dot does not go to screen 12")
        shot(app, "12-screens-on-12")
    }

    /// `>N clear` empties a screen and its page goes: three pages become two.
    func testClearTakesThePageAway() throws {
        let app = launch("clear", ["say Two, then one.", ">2 say Keep me", ">3 say Clear me", ">3 clear"])
        XCTAssertTrue(app.descendants(matching: .any)["page-2"].staticTexts["Keep me"].waitForExistence(timeout: 15), "screen 2 never filled")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["page-tab-3"])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 8), .completed, "the cleared screen kept its dot")
        try expectTabs(app, count: 2)
        shot(app, "clear-2-left")
    }

    /// A screen is full screen (TestFlight feedback on build 57): no nav bar and no
    /// composer, just the dots at the bottom; both come back with the chat.
    func testScreensAreFullScreen() throws {
        let app = launch("full", ["say Plan on screen 2.", ">2 card \"Mazewood MVP\" body=\"One map, 10 waves\"",
                                  ">2 list Build \"Grid map\" Pathfinding +check"])
        let page = app.descendants(matching: .any)["page-2"]
        waitHittable(page.staticTexts["Mazewood MVP"], "screen 2 never showed")
        waitSelected(app.buttons["page-tab-2"], "the reply did not bring screen 2 forward")
        waitGone(app.descendants(matching: .any)["composer"].firstMatch, "the composer is on a screen")
        waitGone(app.buttons["Settings"], "the nav bar is on a screen")
        XCTAssertFalse(app.buttons["Agent menu"].isHittable, "the menu button is on a screen")
        XCTAssertTrue(app.buttons["page-tab-1"].isHittable, "no way back to the chat")
        shot(app, "full-screen-2")
        app.buttons["page-tab-1"].tap()
        waitSelected(app.buttons["page-tab-1"], "the chat glyph does not go to the chat")
        waitHittable(app.descendants(matching: .any)["composer"].firstMatch, "the composer did not come back with the chat")
        waitHittable(app.buttons["Settings"], "the nav bar did not come back with the chat")
        shot(app, "full-back-to-chat")
    }

    // MARK: helpers

    private var tag = ""

    private func launch(_ tag: String, _ lines: [String]) -> XCUIApplication {
        self.tag = tag
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "wizard", "-appearance", "dark",
                               "-yuiThemeDemo", lines.joined(separator: "\\n"), "-yuiDemoPrompt", "Show me the screens"]
        app.launch()
        return app
    }

    /// The indicator shows `count` pages: tabs 1...count exist, the next does not.
    private func expectTabs(_ app: XCUIApplication, count: Int) throws {
        XCTAssertTrue(app.buttons["page-tab-\(count)"].waitForExistence(timeout: 20), "no dot for page \(count)")
        for n in 1...count { XCTAssertTrue(app.buttons["page-tab-\(n)"].exists, "no dot for page \(n)") }
        XCTAssertFalse(app.buttons["page-tab-\(count + 1)"].exists, "a dot for page \(count + 1)")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'page-tab-'")).count, count, "dot count")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "pagecount-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "\(tag)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func waitSelected(_ e: XCUIElement, _ message: String) {
        let p = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "showing"), object: e)
        XCTAssertEqual(XCTWaiter.wait(for: [p], timeout: 6), .completed, message)
    }

    private func waitGone(_ e: XCUIElement, _ message: String) {
        let p = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false OR isHittable == false"), object: e)
        XCTAssertEqual(XCTWaiter.wait(for: [p], timeout: 6), .completed, message)
    }

    private func waitHittable(_ e: XCUIElement, _ message: String, timeout: TimeInterval = 8) {
        let p = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND isHittable == true"), object: e)
        XCTAssertEqual(XCTWaiter.wait(for: [p], timeout: timeout), .completed, message)
    }
}
