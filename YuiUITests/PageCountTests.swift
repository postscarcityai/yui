import XCTest

/// As many screens as the agent uses, up to 12 (TestFlight feedback on build 57):
/// the pager has the chat plus one page per screen with something on it. No dots
/// (YUI-168): VoiceOver hears "Screen 3, 3 of 5" and pages with a swipe up or down.
/// With only the chat there is nothing to page; `>13` stays in the chat; `>N clear`
/// takes the page away. Demo account, no network. Screenshots go to `YUI_SHOTS`.
final class PageCountTests: XCTestCase {
    /// Chat only: a reply with nothing routed to a screen.
    func testChatOnlyHasNoIndicator() throws {
        let app = launch("one", ["say Just the chat today.", "ask \"Start?\""])
        XCTAssertTrue(app.staticTexts["Just the chat today."].waitForExistence(timeout: 15), "the reply never came")
        sleep(1)
        XCTAssertFalse(app.pagePosition.exists, "screens to page with only the chat")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'page-tab-'")).firstMatch.exists, "a dot")
        shot(app, "1-chat-only")
    }

    /// Two pages: the chat and screen 2.
    func testTwoScreens() throws {
        let app = launch("two", ["say One screen.", ">2 list Today Squat|Bench +check"])
        try expectTabs(app, count: 2)
        shot(app, "2-screens")
        app.goToScreen(1)
        waitScreen(app, 1, "paging back does not go to the chat")
        shot(app, "2-screens-chat")
    }

    /// Five pages, numbered as sent.
    func testFiveScreens() throws {
        let app = launch("five", ["say Four screens."] + (2...5).map { ">\($0) say Screen \($0) note" })
        try expectTabs(app, count: 5)
        shot(app, "5-screens")
        app.goToScreen(3)
        let three = app.descendants(matching: .any)["page-3"].staticTexts["Screen 3 note"]
        waitHittable(three, "paging does not go to screen 3")
        waitScreen(app, 3, "screen 3 is not the one on show")
        shot(app, "5-screens-on-3")
    }

    /// Twelve pages, the most; `>13` has no page and stays in the chat.
    func testTwelveScreensAndNoThirteenth() throws {
        let app = launch("twelve", ["say Eleven screens."] + (2...12).map { ">\($0) say Screen \($0) note" } + [">13 say Thirteen stays in the chat"])
        try expectTabs(app, count: 12)
        XCTAssertFalse(app.descendants(matching: .any)["page-13"].exists, "a page for screen 13")
        app.goToScreen(1)
        waitHittable(app.staticTexts["Thirteen stays in the chat"], ">13 did not land in the chat")
        shot(app, "12-screens")
        app.goToScreen(12)
        waitHittable(app.descendants(matching: .any)["page-12"].staticTexts["Screen 12 note"], "paging does not reach screen 12")
        shot(app, "12-screens-on-12")
    }

    /// `>N clear` empties a screen and its page goes: three pages become two.
    func testClearTakesThePageAway() throws {
        let app = launch("clear", ["say Two, then one.", ">2 say Keep me", ">3 say Clear me", ">3 clear"])
        XCTAssertTrue(app.descendants(matching: .any)["page-2"].staticTexts["Keep me"].waitForExistence(timeout: 15), "screen 2 never filled")
        try expectTabs(app, count: 2)
        XCTAssertFalse(app.descendants(matching: .any)["page-3"].exists, "the cleared screen kept its page")
        shot(app, "clear-2-left")
    }

    /// A screen is full screen (TestFlight feedback on build 57): no nav bar and no
    /// composer; both come back with the chat.
    func testScreensAreFullScreen() throws {
        let app = launch("full", ["say Plan on screen 2.", ">2 card \"Mazewood MVP\" body=\"One map, 10 waves\"",
                                  ">2 list Build \"Grid map\" Pathfinding +check"])
        let page = app.descendants(matching: .any)["page-2"]
        waitHittable(page.staticTexts["Mazewood MVP"], "screen 2 never showed")
        waitScreen(app, 2, "the reply did not bring screen 2 forward")
        waitGone(app.descendants(matching: .any)["composer"].firstMatch, "the composer is on a screen")
        XCTAssertFalse(app.buttons["Agent menu"].isHittable, "the menu button is on a screen")
        shot(app, "full-screen-2")
        app.swipeRight()
        waitScreen(app, 1, "a swipe right does not go back to the chat")
        waitHittable(app.descendants(matching: .any)["composer"].firstMatch, "the composer did not come back with the chat")
        waitHittable(app.buttons["Agent menu"], "the nav bar did not come back with the chat")
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

    /// There are `count` pages, and no dots for any of them.
    private func expectTabs(_ app: XCUIApplication, count: Int) throws {
        waitScreens(app, count, "not \(count) screens")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'page-tab-'")).count, 0, "dots on the screens")
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

    private func waitGone(_ e: XCUIElement, _ message: String) {
        let p = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false OR isHittable == false"), object: e)
        XCTAssertEqual(XCTWaiter.wait(for: [p], timeout: 6), .completed, message)
    }

    private func waitHittable(_ e: XCUIElement, _ message: String, timeout: TimeInterval = 8) {
        let p = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND isHittable == true"), object: e)
        XCTAssertEqual(XCTWaiter.wait(for: [p], timeout: timeout), .completed, message)
    }
}
