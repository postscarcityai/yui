import XCTest

/// The agent's drawer (YUI-54, "Peek and tabs"): a drag right on the chat pulls it
/// out from the left and it stops short so the chat peeks out. Home shows the
/// pinned screen and what's next; Review opens the ask in place and answers it;
/// the agent bar at the bottom opens the switcher. On a screen, a drag right
/// pages back to the chat first. Demo account, no network. Shots go to `YUI_SHOTS`.
final class DrawerTests: XCTestCase {
    static let reply = [
        "say Three drawer mocks are ready.",
        #"card "Pick a drawer" body="Calm list, playful tiles, or peek and tabs.""#,
        #"choose@drawer "Which one do I build?" Calm|Playful|Peek"#,
        ">2",
        #"card "Leg day" sub="Five moves, 40 minutes""#,
        "timer 45s Squats",
        "save workout",
    ].joined(separator: "\\n")

    func testLight() throws { try run("light") }
    func testDark() throws { try run("dark") }
    func testReduceMotion() throws { try run("light", reduceMotion: true) }

    private func run(_ appearance: String, reduceMotion: Bool = false) throws {
        let tag = "drawer-\(appearance)\(reduceMotion ? "-reduce" : "")"
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
                               "-yuiThemeDemo", Self.reply, "-yuiDemoPrompt", "Can the agent menu come out from the left?"]
        if reduceMotion { app.launchArguments += ["-yuiReduceMotion"] }
        app.launch()

        let close = app.buttons["drawer-close"]
        // The reply lands; its second half goes to screen 2, which comes forward.
        let squats = app.descendants(matching: .any)["page-2"].staticTexts["Squats"]
        XCTAssertTrue(squats.waitForExistence(timeout: 20), "the workout never reached screen 2")
        waitHittable(squats, "screen 2 did not come forward")
        sleep(1)

        // On a screen, a drag right pages back to the chat, and does not open the drawer.
        app.swipeRight()
        let menu = app.buttons["Agent menu"]
        waitHittable(menu, "a drag right on screen 2 did not page back to the chat")
        XCTAssertFalse(close.exists, "the drawer opened from screen 2")
        XCTAssertEqual(menu.value as? String, "1 waiting on you", "the menu button has no count for the open question")
        
        sleep(1)
        shot("0-chat")

        // On the chat, a drag right from the middle of the thread pulls the drawer out.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.55))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.56)))
        XCTAssertTrue(close.waitForExistence(timeout: 5), "a drag right on the chat did not open the drawer")
        if !close.exists { return }
        waitHittable(close, "the drawer did not settle open")
        // It stops short: the drawer's right edge sits inside the screen.
        XCTAssertLessThan(app.buttons["drawer-agent-bar"].frame.maxX, app.frame.maxX - 20, "the drawer covers the whole width")
        XCTAssertTrue(app.buttons["drawer-pin-workout"].waitForExistence(timeout: 3), "no pinned workout on Home")
        XCTAssertTrue(app.buttons["drawer-next-up"].exists, "no next-up for the open question")
        sleep(1)
        shot("1-home")

        // A drag left on the drawer closes it.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)))
        waitGone(close, "a drag left did not close the drawer")
        sleep(1)

        // The top-left button opens it too. Review: the ask opens in place with its answers.
        menu.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the menu button did not open the drawer")
        app.buttons["drawer-tab-review"].tap()
        // The chat's copy of the ask sits under the drawer; the drawer's is the one on top.
        XCTAssertTrue(app.buttons["review-drawer"].waitForExistence(timeout: 5), "no review card")
        XCTAssertTrue(app.buttons.matching(identifier: "Peek").element(boundBy: 1).waitForExistence(timeout: 5),
                      "the ask did not open in place on Review")
        let answer = app.buttons.matching(identifier: "Peek").allElementsBoundByIndex.first { $0.isHittable }!
        sleep(1)
        shot("2-review-open")
        answer.tap()
        XCTAssertTrue(app.staticTexts["All caught up."].waitForExistence(timeout: 5), "the answered ask stayed on Review")
        sleep(1)
        shot("3-review-done")

        // Controls and About.
        app.buttons["drawer-tab-controls"].tap()
        XCTAssertTrue(app.buttons["drawer-edit-agent"].waitForExistence(timeout: 3), "no controls")
        sleep(1)
        shot("4-controls")
        app.buttons["drawer-tab-about"].tap()
        XCTAssertTrue(app.staticTexts["What it does"].waitForExistence(timeout: 3), "no About")
        sleep(1)
        shot("5-about")

        // The agent at the bottom: the switcher springs up; pick Coach.
        app.buttons["drawer-agent-bar"].tap()
        let coach = app.buttons["switch-Coach"]
        XCTAssertTrue(coach.waitForExistence(timeout: 5), "the switcher did not open")
        waitHittable(coach, "Coach is not tappable in the switcher")
        sleep(1)
        shot("6-switcher")
        coach.tap()
        waitGone(close, "picking an agent did not close the drawer")
        let header = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Talking to Coach")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5), "the chat did not switch to Coach")
        sleep(1)
        shot("7-coach")
    }

    private func waitHittable(_ e: XCUIElement, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
        let x = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND isHittable == true"), object: e)
        XCTAssertEqual(XCTWaiter.wait(for: [x], timeout: 6), .completed, why, file: file, line: line)
    }

    private func waitGone(_ e: XCUIElement, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
        let x = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: e)
        XCTAssertEqual(XCTWaiter.wait(for: [x], timeout: 6), .completed, why, file: file, line: line)
    }
}
