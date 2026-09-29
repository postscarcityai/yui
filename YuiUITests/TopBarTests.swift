import XCTest

/// The top bar (YUI-122, YUI-193): the menu top left, the screen pills after it when there are screens, the record top right, the
/// same on the full screen and in the record. The menu opens the drawer, and Settings
/// lives in it; the agent picker at the bottom of the drawer switches who you talk to; the record button opens the
/// thread and its top right comes back. Demo account, no network. Screenshots go to
/// `YUI_SHOTS` when set, and always into the result bundle.
final class TopBarTests: XCTestCase {
    func testTheTopBarLight() throws { try topBar("light") }
    func testTheTopBarDark() throws { try topBar("dark") }

    private func topBar(_ appearance: String) throws {
        let app = launch(appearance)
        let menu = app.buttons["stage-menu"], record = app.buttons["stage-record"]
        XCTAssertTrue(app.descendants(matching: .any)["stage-greeting"].waitForExistence(timeout: 15), "no stage at launch")

        // The menu top left, the record top right, and nothing between them with no screens:
        // the agent picker left the bar (YUI-193) and the screen pills only show with screens.
        XCTAssertTrue(menu.exists && record.exists, "the stage's top bar is missing a button")
        XCTAssertFalse(app.buttons["stage-agents"].exists, "the agent pill is still in the top bar")
        XCTAssertFalse(app.descendants(matching: .any)["screen-pills"].exists, "screen pills with no screens")
        XCTAssertLessThan(menu.frame.maxX, app.frame.width / 3, "the menu is not top left")
        XCTAssertGreaterThan(record.frame.maxX, app.frame.width - 110, "the record is not top right")
        for e in [menu, record] { XCTAssertLessThan(e.frame.minY, 120, "\(e.identifier) is not at the top") }
        sleep(1)
        shot("1-stage-top", appearance)

        // The agent picker lives at the bottom of the drawer: every agent, tap one to switch.
        menu.tap()
        let agents = app.buttons["drawer-agent-bar"]
        XCTAssertTrue(agents.waitForExistence(timeout: 5), "the drawer has no agent picker")
        XCTAssertTrue(agents.label.hasPrefix("Talking to Yui"), "the picker does not say who: \(agents.label)")
        agents.tap()
        let coach = app.buttons["switch-Coach"]
        XCTAssertTrue(coach.waitForExistence(timeout: 5), "the switcher did not list the agents")
        XCTAssertTrue(app.buttons["switch-manage"].exists, "no Edit list in the switcher")
        XCTAssertTrue(app.buttons["switch-add"].exists, "no Add an agent in the switcher")
        sleep(1)
        shot("2-switch-agent", appearance)
        coach.tap()
        XCTAssertTrue(waitGone(app.buttons["drawer-close"]), "the drawer stayed open after the switch")
        XCTAssertTrue(app.talkingTo().hasPrefix("Talking to Coach"), "the stage did not switch to Coach")
        XCTAssertTrue(app.descendants(matching: .any)["stage-greeting"].exists, "the stage left after the switch")
        sleep(1)
        shot("3-switched", appearance)

        // The menu: the drawer over the full screen, with Settings in it.
        menu.tap()
        let settings = app.buttons["drawer-settings"], close = app.buttons["drawer-close"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "the menu did not open the drawer")
        waitHittable(settings, "Settings in the drawer is not tappable over the stage")
        sleep(1)
        shot("4-menu-on-stage", appearance)
        settings.tap()
        XCTAssertTrue(app.staticTexts["Make Yui feel like yours."].waitForExistence(timeout: 5), "Settings did not open")
        XCTAssertTrue(waitGone(close), "the drawer stayed open under Settings")
        sleep(1)
        shot("5-settings", appearance)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.53))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99)))
        XCTAssertTrue(waitGone(app.staticTexts["Make Yui feel like yours."]), "Settings did not close")
        XCTAssertTrue(app.descendants(matching: .any)["stage-first"].exists, "Settings closed onto something other than the stage")

        // The record, top right: the same top left, the way back top right.
        record.tap()
        let back = app.buttons["back-to-stage"], rmenu = app.buttons["Agent menu"]
        let ragents = app.recordTitle("Coach")
        XCTAssertTrue(back.waitForExistence(timeout: 5), "the record has no way back")
        waitHittable(rmenu, "no menu in the record")
        XCTAssertTrue(ragents.exists, "no agent title in the record")
        XCTAssertLessThan(rmenu.frame.maxX, ragents.frame.minX, "the record's menu is not left of the agent")
        XCTAssertGreaterThan(back.frame.maxX, app.frame.width - 110, "the way back is not top right")
        XCTAssertFalse(app.buttons["record-agents"].exists, "the chip is back in the record's bar")
        XCTAssertFalse(app.buttons["Settings"].exists, "Settings is still loose in the record's bar")
        sleep(1)
        shot("6-record-top", appearance)
        rmenu.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "the record's menu did not open the drawer with Settings")
        sleep(1)
        shot("7-menu-in-record", appearance)
        close.tap()
        XCTAssertTrue(waitGone(close), "the drawer did not close")
        back.tap()
        XCTAssertTrue(app.descendants(matching: .any)["stage-first"].waitForExistence(timeout: 5), "the stage did not come back")
    }

    // MARK: Helpers

    private func launch(_ appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "yui",
                               "-appearance", appearance]
        app.launch()
        return app
    }

    private func waitHittable(_ e: XCUIElement, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
        let x = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND isHittable == true"), object: e)
        XCTAssertEqual(XCTWaiter.wait(for: [x], timeout: 6), .completed, why, file: file, line: line)
    }

    private func waitGone(_ e: XCUIElement) -> Bool {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: e)],
                         timeout: 5) == .completed
    }

    private func shot(_ name: String, _ appearance: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "top-bar-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "top-bar-\(appearance)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }
}
