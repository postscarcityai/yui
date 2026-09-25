import XCTest

/// Agents fill the drawer (YUI-86, spec YL.md section 5, The drawer). A reply's
/// `menu` lines draw nothing in the chat: a review item counts on the menu button
/// and sits in Review, backlog items get their own section on Home, and the agent's
/// shortcuts sit above the host's commands. A tap on a review item goes back to the
/// agent; a shortcut sends its words, or with `say=` ending in a space puts them in
/// the composer. The reply's `card +fold` opens in place and folds again. Demo
/// account, no network. Shots go to `YUI_SHOTS`.
final class MenuDrawerTests: XCTestCase {
    static let reply = [
        "say Your deload week is drafted. The rest is in your drawer.",
        #"card "Deload week" "Lighter sets at 60 percent, one more hour of sleep, and two easy walks. Monday and Thursday stay short; Saturday is the long walk." sub="Draft 2" tag=Plan +fold"#,
        #"menu review@dana "Invite Dana to the beta?" sub="asked yesterday""#,
        #"menu backlog@deload "Deload week plan" sub=drafting"#,
        #"menu backlog@trip "Meal plan for the trip" sub=queued"#,
        #"menu shortcut "Start the workout""#,
        #"menu shortcut@log "Log a meal" say="Log a meal: ""#,
    ].joined(separator: "\\n")

    func testLight() throws { try run("light") }
    func testDark() throws { try run("dark") }

    private func run(_ appearance: String) throws {
        let tag = "menu-\(appearance)"
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
                try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(tag)-\(name).png"))
            }
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = "\(tag)-\(name)"
            a.lifetime = .keepAlways
            add(a)
        }

        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "wizard", "-appearance", appearance,
                               "-yuiThemeDemo", Self.reply, "-yuiDemoPrompt", "Plan my deload week?",
                               "-yuiDemoReply", "say Here we go."]
        app.launch()

        // The folded card: title and a line of body, then open in place and fold again.
        let fold = app.buttons["card-fold-n2"]
        XCTAssertTrue(fold.waitForExistence(timeout: 20), "the folded card never landed")
        waitHittable(fold, "the folded card is not tappable")
        XCTAssertEqual(fold.value as? String, "Folded")
        sleep(1)
        shot("0-card-folded")
        fold.tap()
        waitValue(fold, "Open", "a tap did not open the card")
        sleep(1)
        shot("1-card-open")
        fold.tap()
        waitValue(fold, "Folded", "a second tap did not fold the card")

        // The menu lines drew nothing; the review item counts on the button.
        XCTAssertFalse(app.staticTexts["Deload week plan"].exists, "a menu line drew in the chat")
        let menu = app.buttons["Agent menu"]
        XCTAssertEqual(menu.value as? String, "1 waiting on you", "the review item is not counted")

        // Home: next up, the backlog and the agent's shortcuts.
        menu.tap()
        let close = app.buttons["drawer-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the menu button did not open the drawer")
        waitHittable(close, "the drawer did not settle open")
        XCTAssertTrue(app.buttons["drawer-next-up"].exists, "no next-up for the review item")
        XCTAssertTrue(app.buttons["drawer-backlog-deload"].exists, "no backlog item")
        XCTAssertTrue(app.buttons["drawer-backlog-trip"].exists, "no second backlog item")
        let log = app.buttons["drawer-shortcut-log"]
        let start = app.buttons["drawer-shortcut-start-the-workout"]
        XCTAssertTrue(log.exists && start.exists, "no agent shortcuts")
        // Newest first: the trip was added after the deload plan.
        XCTAssertLessThan(app.buttons["drawer-backlog-trip"].frame.minY, app.buttons["drawer-backlog-deload"].frame.minY)
        sleep(1)
        shot("2-home")

        // Review: the agent's item as a card; a tap goes back to the agent and closes the drawer.
        app.buttons["drawer-tab-review"].tap()
        let dana = app.buttons["review-menu-dana"]
        XCTAssertTrue(dana.waitForExistence(timeout: 5), "no review item on Review")
        sleep(1)
        shot("3-review")
        dana.tap()
        waitGone(close, "a tap on the review item did not close the drawer")
        XCTAssertTrue(app.staticTexts["Invite Dana to the beta?"].waitForExistence(timeout: 5),
                      "the tap did not go back to the agent as the person's reply")

        // A shortcut with say= ending in a space goes in the composer to finish.
        menu.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        waitHittable(close, "the drawer did not settle open again")
        if !app.buttons["drawer-shortcut-log"].isHittable { app.buttons["drawer-tab-home"].tap() }
        waitHittable(app.buttons["drawer-shortcut-log"], "the log shortcut is not on Home")
        app.buttons["drawer-shortcut-log"].tap()
        waitGone(close, "the shortcut did not close the drawer")
        let field = app.textFields["composer"].exists ? app.textFields["composer"] : app.textViews["composer"]
        let typed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", "Log a meal:"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [typed], timeout: 5), .completed, "the shortcut did not fill the composer")
        sleep(1)
        shot("4-composer")

        // A plain shortcut sends its label as the person's message.
        menu.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        waitHittable(app.buttons["drawer-shortcut-start-the-workout"], "the workout shortcut is not tappable")
        app.buttons["drawer-shortcut-start-the-workout"].tap()
        waitGone(close, "the shortcut did not close the drawer")
        XCTAssertTrue(app.staticTexts["Start the workout"].waitForExistence(timeout: 5), "the shortcut was not sent")
        XCTAssertTrue(app.staticTexts["Here we go."].waitForExistence(timeout: 8), "the agent did not answer the shortcut")
        sleep(1)
        shot("5-sent")
    }

    private func waitHittable(_ e: XCUIElement, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
        let x = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND isHittable == true"), object: e)
        XCTAssertEqual(XCTWaiter.wait(for: [x], timeout: 6), .completed, why, file: file, line: line)
    }

    private func waitGone(_ e: XCUIElement, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
        let x = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: e)
        XCTAssertEqual(XCTWaiter.wait(for: [x], timeout: 6), .completed, why, file: file, line: line)
    }

    private func waitValue(_ e: XCUIElement, _ value: String, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
        let x = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: e)
        XCTAssertEqual(XCTWaiter.wait(for: [x], timeout: 5), .completed, why, file: file, line: line)
    }
}
