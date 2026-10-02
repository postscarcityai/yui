import XCTest

/// The menu pill (feedback ANG8AA-7k6WmMJEx633zmMg, Chris: "I don't actually know where I am ... put the agent name on
/// the hamburger"): the top-left button on the stage is the menu icon and the agent's name, and the whole pill opens the
/// drawer. A short name and a long one (it truncates, the bar keeps its other buttons). Demo account, no network.
/// Shots go to `YUI_SHOTS` when set, and always into the result bundle.
final class MenuPillTests: XCTestCase {
    func testMenuPillShortNameDark() throws { try pill("dark", agent: "coach", name: "Coach", long: false) }
    func testMenuPillShortNameLight() throws { try pill("light", agent: "coach", name: "Coach", long: false) }
    func testMenuPillLongNameDark() throws { try pill("dark", agent: "coach", name: "Coach of the Quarterly", long: true) }
    func testMenuPillLongNameLight() throws { try pill("light", agent: "coach", name: "Coach of the Quarterly", long: true) }

    private func pill(_ appearance: String, agent: String, name: String, long: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", agent,
                               "-appearance", appearance] + (long ? ["-yuiDemoLongName"] : [])
        app.launch()
        let menu = app.buttons["stage-menu"], record = app.buttons["stage-record"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15), "no menu on the stage")
        XCTAssertTrue(app.descendants(matching: .any)["stage-greeting"].waitForExistence(timeout: 15), "no stage at launch")

        // The pill says who you are talking to, and sits top left, clear of the record button.
        XCTAssertTrue(menu.label.contains(name), "the menu does not say the agent: \(menu.label)")
        XCTAssertGreaterThan(menu.frame.width, 80, "the menu is still a bare circle")
        XCTAssertLessThan(menu.frame.minX, 24, "the menu is not top left")
        XCTAssertLessThan(menu.frame.maxX, record.frame.minX, "a long name pushed the record button off")
        let newChat = app.buttons["stage-new-chat"]
        XCTAssertTrue(record.exists && newChat.exists, "the right buttons are missing")
        XCTAssertLessThanOrEqual(newChat.frame.maxX, app.frame.width, "a long name pushed the new chat button off screen")
        sleep(1)
        shot("pill-\(long ? "long" : "short")", appearance)

        // Tap the name end of the pill: the drawer opens, same as the icon.
        menu.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["drawer-close"].waitForExistence(timeout: 5), "tapping the name did not open the drawer")
    }

    private func shot(_ name: String, _ appearance: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "menu-pill-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "menu-pill-\(appearance)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }
}
