import XCTest

/// Group threads (YUI-94): the New group sheet from the agent list, a thread with a handoff row, a guard
/// row (Let it), an offline line, and Stop on a working row; then the same group again in dark.
///
/// Driven by supabase/tests/group_e2e.py --sim <udid>, which makes a throwaway account with three agents
/// (Alpha and Bravo served by real Yui adapters on this Mac, Cleo stopped) and hands over one FRESH refresh
/// token per launch (a spent one signs out every device):
///
///   TEST_RUNNER_YUI_RTS=<rt1>,<rt2> TEST_RUNNER_YUI_USER=<uuid> TEST_RUNNER_YUI_SHOTS=/tmp/shots \
///     xcodebuild test -scheme Yui -destination '...' -only-testing:YuiUITests/GroupTests
final class GroupTests: XCTestCase {
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

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func launch(_ rt: String, _ user: String, _ appearance: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiRefreshToken", rt, "-yuiUserID", user, "-yuiAgent", "alpha", "-appearance", appearance] + extra
        app.launch()
        return app
    }

    private func say(_ app: XCUIApplication, _ words: String) {
        let field = any(app, "group-field")
        XCTAssertTrue(field.waitForExistence(timeout: 15), "no group composer")
        field.tap()
        field.typeText(words)
        let send = any(app, "group-send")
        XCTAssertTrue(send.isEnabled)
        send.tap()
    }

    func testGroupLightThenDark() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rts = env["YUI_RTS"]?.split(separator: ",").map(String.init), rts.count >= 2,
              let user = env["YUI_USER"] else {
            throw XCTSkip("set TEST_RUNNER_YUI_RTS (two refresh tokens) and TEST_RUNNER_YUI_USER; see group_e2e.py")
        }

        // Light: make the group from the agent list.
        let app = launch(rts[0], user, "light", extra: ["-yuiAgents", "-yuiNewGroup"])
        XCTAssertTrue(any(app, "group-create").waitForExistence(timeout: 40), "no New group sheet")
        sleep(2)  // the agent list loads after sign-in
        shot("group-light-00-sheet")
        XCTAssertFalse(any(app, "group-create").isEnabled, "needs two agents and a name")
        // Alpha first: the lead.
        any(app, "group-pick-alpha").tap()
        any(app, "group-pick-bravo").tap()
        any(app, "group-pick-cleo").tap()
        XCTAssertTrue(any(app, "group-lead-alpha").waitForExistence(timeout: 5), "no lead row")
        let name = any(app, "group-name")
        name.tap()
        name.typeText("Race week")
        shot("group-light-01-new-group")
        any(app, "group-create").tap()
        XCTAssertTrue(any(app, "group-thread").waitForExistence(timeout: 20), "the group did not open")
        shot("group-light-01b-opened")
        XCTAssertTrue(any(app, "group-face-alpha").waitForExistence(timeout: 15), "no header")

        // Max hops 1 in settings, so Bravo's @alpha trips the guard.
        any(app, "group-settings").tap()
        let hops = app.steppers["group-hops"]
        XCTAssertTrue(hops.waitForExistence(timeout: 10))
        shot("group-light-02-settings-before")
        // The minus sits right of the row's middle (the stepper is one element).
        for _ in 0..<2 { hops.coordinate(withNormalizedOffset: CGVector(dx: 0.77, dy: 0.5)).tap() }
        XCTAssertTrue(app.staticTexts["Max hops: 1"].waitForExistence(timeout: 10), "hops did not go to 1")
        shot("group-light-02-settings")
        app.buttons["Done"].firstMatch.tap()

        // Talk to the lead, then ask Alpha to ask Bravo: handoff row, then the guard.
        say(app, "How did I sleep?")
        XCTAssertTrue(app.staticTexts["Alpha here."].waitForExistence(timeout: 60), "the lead did not answer")
        say(app, "@Bravo does this fit my knee?")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Box squats")).firstMatch
            .waitForExistence(timeout: 60), "Bravo did not answer")
        say(app, "@Alpha please ask bravo about Sunday")
        XCTAssertTrue(any(app, "group-handoff").waitForExistence(timeout: 60), "no handoff row")
        XCTAssertTrue(any(app, "group-guard").waitForExistence(timeout: 90), "no guard row")
        XCTAssertTrue(any(app, "group-letit").exists && any(app, "group-stophere").exists)
        shot("group-light-03-handoff-and-guard")
        any(app, "group-letit").tap()
        XCTAssertTrue(app.staticTexts["Let through."].waitForExistence(timeout: 30), "the guard did not read Let through")

        // Offline agent: one line in its look.
        say(app, "@Cleo are you there?")
        XCTAssertTrue(any(app, "group-status").waitForExistence(timeout: 30), "no status line for Cleo")
        shot("group-light-04-status")

        // Stop while Bravo works the slow ask.
        say(app, "@Alpha please ask bravo slow")
        let stop = any(app, "group-stop-bravo")
        XCTAssertTrue(stop.waitForExistence(timeout: 60), "no working row with Stop for Bravo")
        shot("group-light-05-working")
        stop.tap()
        XCTAssertTrue(app.staticTexts["Stopped."].waitForExistence(timeout: 30), "no Stopped line")
        shot("group-light-06-stopped")

        // Dark: the same group from the list.
        let dark = launch(rts[1], user, "dark", extra: ["-yuiAgents"])
        let row = any(dark, "group-row")
        // The sheet opens medium: the groups sit under the agents, and rows scrolled out are not drawn yet.
        XCTAssertTrue(any(dark, "agents-greeting").waitForExistence(timeout: 40), "no agent list")
        sleep(3)
        for _ in 0..<4 where !row.exists { dark.swipeUp(); sleep(1) }
        shot("group-dark-01-list")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the group is not in the agent list")
        row.tap()
        XCTAssertTrue(any(dark, "group-thread").waitForExistence(timeout: 20))
        XCTAssertTrue(any(dark, "group-handoff").waitForExistence(timeout: 20), "the handoff row did not reload")
        XCTAssertTrue(any(dark, "group-guard").exists)
        sleep(1)
        shot("group-dark-02-thread")
    }
}
