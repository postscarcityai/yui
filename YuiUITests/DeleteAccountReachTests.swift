import XCTest

/// Delete account in reach (YUI-237, found by the YUI-218 stranger run: 17 s of scrolling).
/// From the drawer: tap Settings (1), and Delete account is on screen, hittable, without a scroll. Logs the time.
/// Demo account, no network. Shots go to `YUI_SHOTS` when set.
final class DeleteAccountReachTests: XCTestCase {
    func testDeleteAccountInReachLight() throws { try reach("light") }
    func testDeleteAccountInReachDark() throws { try reach("dark") }

    private func reach(_ appearance: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "yui",
                               "-appearance", appearance]
        app.launch()
        let menu = app.buttons["stage-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15), "no stage at launch")

        let start = Date()
        var taps = 0
        menu.tap(); taps += 1
        let settings = app.buttons["drawer-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "no Settings in the drawer")
        let drawerAt = Date().timeIntervalSince(start)
        settings.tap(); taps += 1
        let delete = app.buttons["Delete account"]
        let hit = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND isHittable == true"), object: delete)
        XCTAssertEqual(XCTWaiter.wait(for: [hit], timeout: 5), .completed, "Delete account is not on screen after \(taps) taps")
        let secs = Date().timeIntervalSince(start)
        print("YUI-237 \(appearance): drawer to Delete account hittable in \(taps) taps, \(String(format: "%.2f", secs)) s (drawer open at \(String(format: "%.2f", drawerAt)) s)")
        XCTAssertLessThanOrEqual(taps, 2)
        // XCUITest idle-waits add seconds per tap; 5 s is the goal, 15 s the noise guard. The time is logged above.
        XCTAssertLessThan(secs, 15, "Delete account took \(secs) s")
        sleep(1)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "settings-\(appearance).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "settings-\(appearance)"; a.lifetime = .keepAlways; add(a)

        // The confirm sheet is unchanged: it still opens from the button.
        delete.tap()
        XCTAssertTrue(app.staticTexts["Delete your Yui account?"].waitForExistence(timeout: 5), "the confirm sheet did not open")
    }
}
