import XCTest

/// Screens beside the chat (YUI-31): a reply sends a focus timer to screen 2
/// and a list to screen 3, the app brings screen 3 forward, and the person
/// swipes back through screen 2 to the chat, where pills go back to each page.
/// Runs on the demo account, no network. Screenshots go to `YUI_SHOTS` when set.
final class PagesTests: XCTestCase {
    static let reply = [
        "say Timer on screen 2, your list on screen 3.",
        ">2 timer 25m Focus",
        ">3 list@shop Shopping Eggs|Spinach|Rice|Gochujang +check",
    ].joined(separator: "\\n")

    func testLinesLandOnPagesAndSwipeBack() throws {
        try run(appearance: "light", agent: "wizard")
    }

    func testDark() throws {
        try run(appearance: "dark", agent: "wizard")
    }

    /// Reduce Motion: the same trip, pages cross-fade instead of sliding.
    func testReduceMotion() throws {
        try run(appearance: "light", agent: "wizard", reduceMotion: true)
    }

    private func run(appearance: String, agent: String, reduceMotion: Bool = false) throws {
        let shots = ProcessInfo.processInfo.environment["YUI_SHOTS"].map { URL(fileURLWithPath: $0) }
        let tag = "\(appearance)-\(agent)\(reduceMotion ? "-reduce" : "")"
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            if let shots { try? png.write(to: shots.appending(path: "pages-\(tag)-\(name).png")) }
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = "\(tag)-\(name)"
            a.lifetime = .keepAlways
            add(a)
        }

        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", agent, "-appearance", appearance,
                               "-yuiThemeDemo", Self.reply, "-yuiDemoPrompt", "Cooking bibimbap, keep me on track"]
        if reduceMotion { app.launchArguments += ["-yuiReduceMotion"] }
        app.launch()

        let tab = { (n: Int) in app.buttons["page-tab-\(n)"] }
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 10) || app.textViews.firstMatch.exists, "no composer")
        shot("0-chat")

        // The reply streams in: the timer goes to 2, then the list brings 3 forward.
        // Scoped to the page: the chat's pills carry the same words, off screen.
        let eggs = app.descendants(matching: .any)["page-3"].staticTexts["Eggs"]
        XCTAssertTrue(eggs.waitForExistence(timeout: 15), "the list never reached screen 3")
        waitHittable(eggs, "screen 3 did not come forward")
        waitSelected(tab(3), "the tab does not say screen 3")
        
        sleep(1)
        shot("1-screen-3")

        // Tap an item on the page: it answers like it would in the chat.
        eggs.tap()

        // Swipe right: screen 2, the focus timer.
        app.swipeRight()
        let focus = app.descendants(matching: .any)["page-2"].staticTexts["Focus"]
        waitHittable(focus, "swiping right did not show screen 2")
        waitSelected(tab(2), "the tab does not say screen 2")
        XCTAssertFalse(eggs.isHittable, "screen 3 is still showing")
        sleep(1)
        shot("2-screen-2")

        // Swipe right again: the chat, with one pill per page.
        app.swipeRight()
        let pill3 = app.buttons["Go to screen 3, Shopping"]
        waitHittable(pill3, "no screen 3 pill in the chat")
        XCTAssertTrue(app.buttons["Go to screen 2, Focus"].exists, "no screen 2 pill in the chat")
        waitSelected(tab(1), "the tab does not say Chat")
        shot("3-chat-pills")

        // The pill goes to its page, and the page kept the tick.
        pill3.tap()
        waitHittable(eggs, "the pill did not open screen 3")
        waitSelected(tab(3), "the pill did not select screen 3")
        shot("4-back-on-3")

        // A tab goes straight to a page, and swiping left moves on from it.
        tab(1).tap()
        waitHittable(pill3, "the Chat tab did not go back to the chat")
        app.swipeLeft()
        waitHittable(focus, "swiping left from the chat did not show screen 2")
        shot("5-swiped-left")
    }

    private func waitSelected(_ e: XCUIElement, _ message: String) {
        let p = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "showing"), object: e)
        XCTAssertEqual(XCTWaiter.wait(for: [p], timeout: 6), .completed, message)
    }

    private func waitHittable(_ e: XCUIElement, _ message: String, timeout: TimeInterval = 6) {
        let p = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND isHittable == true"), object: e)
        XCTAssertEqual(XCTWaiter.wait(for: [p], timeout: timeout), .completed, message)
    }
}
