import XCTest

/// INT-19: the person's side of adding Yui to an OAuth-only MCP client. The
/// driver (supabase/tests/mcp_oauth_e2e.py) runs the MCP TypeScript SDK's own
/// OAuth client against yui-mcp: discovery, registration, PKCE. When the SDK
/// sends the browser to www.yuigui.com/connect/<id>, the driver writes that id
/// into the shots folder as `connect`; this test opens `yui://connect/<id>` like
/// the page's Open Yui button, taps Allow, opens the new thread, and plays the
/// person: the client asks "Ready for a tabata?", the test taps Yes, the client
/// answers with a timer. Needs a fresh refresh token per run (a spent one signs
/// every device out) and only runs when `TEST_RUNNER_YUI_RT` /
/// `TEST_RUNNER_YUI_USER` are set.
final class ConnectApprovalTests: XCTestCase {
    func testAllowConnectsAClient() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rt = env["YUI_RT"], let user = env["YUI_USER"], let dir = env["YUI_SHOTS"] else {
            throw XCTSkip("set TEST_RUNNER_YUI_RT, TEST_RUNNER_YUI_USER and TEST_RUNNER_YUI_SHOTS to run against the live backend")
        }
        let shots = URL(fileURLWithPath: dir)
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            try? png.write(to: shots.appending(path: "\(name).png"))
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = name
            a.lifetime = .keepAlways
            add(a)
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let app = XCUIApplication()
        app.launchArguments = ["-yuiRefreshToken", rt, "-yuiUserID", user, "-appearance", env["YUI_APPEARANCE"] ?? "light"]
        app.launch()
        let allowPush = springboard.buttons["Allow"]
        if allowPush.waitForExistence(timeout: 10) { allowPush.tap() }
        // A new account has no agents yet: its first-run screen, not a thread.
        _ = app.buttons.firstMatch.waitForExistence(timeout: 20)
        sleep(3)
        shot("00-signed-in")
        try? Data().write(to: shots.appending(path: "ready"))

        // The driver's SDK client reached /authorize: its request id.
        var id = ""
        let deadline = Date().addingTimeInterval(180)
        while id.isEmpty, Date() < deadline {
            id = (try? String(contentsOf: shots.appending(path: "connect"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if id.isEmpty { sleep(1) }
        }
        XCTAssertFalse(id.isEmpty, "the OAuth client never reached /authorize")
        // The system opens the link, like the page's button: no relaunch, so the
        // app keeps its session (a relaunch would replay the spent refresh token).
        XCUIDevice.shared.system.open(URL(string: "yui://connect/\(id)")!)
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 3) { open.tap() }

        XCTAssertTrue(app.staticTexts["connectTitle"].waitForExistence(timeout: 20), "no connect sheet")
        sleep(1)
        shot("01-connect-sheet")
        app.buttons["connectAllow"].tap()
        XCTAssertTrue(app.staticTexts["connectResult"].waitForExistence(timeout: 20))
        shot("02-connected")
        app.buttons["connectOpenThread"].tap()

        let yes = app.buttons["Yes"].firstMatch
        XCTAssertTrue(yes.waitForExistence(timeout: 240), "the client's ask screen never arrived")
        sleep(1)
        shot("03-ask-from-oauth-client")
        yes.tap()
        let start = app.buttons.matching(NSPredicate(format: "label == %@", "Start")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 240), "no timer came back after tapping Yes")
        sleep(1)
        shot("04-timer-from-oauth-client")
    }
}
