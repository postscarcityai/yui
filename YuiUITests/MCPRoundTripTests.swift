import XCTest

/// INT-3: the person's side of a Yui MCP round trip. An MCP client (Claude Code,
/// driven by supabase/tests/mcp_claude_e2e.py) asks "Ready for a tabata?" with
/// Yes / Not now through yui_show, this test taps Yes, and the client answers
/// with a timer after reading the tap through yui_answers. Needs a fresh refresh
/// token per run (a spent one signs every device out) and only runs when
/// `TEST_RUNNER_YUI_RT` / `TEST_RUNNER_YUI_USER` are set:
///
///   TEST_RUNNER_YUI_RT=<refresh token> TEST_RUNNER_YUI_USER=<uuid> TEST_RUNNER_YUI_SHOTS=/tmp/shots \
///     xcodebuild test -scheme Yui -destination '...' -only-testing:YuiUITests/MCPRoundTripTests
///
/// The test writes `ready` into the shots folder once the thread is on screen,
/// so the driver starts the MCP client only then.
final class MCPRoundTripTests: XCTestCase {
    func testClientDrawsScreenAndTimer() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rt = env["YUI_RT"], let user = env["YUI_USER"] else {
            throw XCTSkip("set TEST_RUNNER_YUI_RT and TEST_RUNNER_YUI_USER to run against the live backend")
        }
        let shots = env["YUI_SHOTS"].map { URL(fileURLWithPath: $0) }
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            if let shots { try? png.write(to: shots.appending(path: "\(name).png")) }
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = name
            a.lifetime = .keepAlways
            add(a)
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        let app = XCUIApplication()
        app.launchArguments = ["-yuiRefreshToken", rt, "-yuiUserID", user, "-appearance", "light"]
        app.launch()

        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 15) { allow.tap() }
        let field = app.descendants(matching: .any).matching(NSPredicate(format: "placeholderValue == %@ OR label == %@", "Say something nice", "Say something nice")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        shot("01-thread-loaded")
        if let shots { try? Data().write(to: shots.appending(path: "ready")) }

        let yes = app.buttons["Yes"].firstMatch
        XCTAssertTrue(yes.waitForExistence(timeout: 240), "the MCP client's ask screen never arrived")
        sleep(1)
        shot("02-ask-from-mcp")
        yes.tap()
        shot("03-tapped-yes")

        let start = app.buttons.matching(NSPredicate(format: "label == %@", "Start")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 240), "no timer came back after tapping Yes")
        sleep(1)
        shot("04-timer-from-mcp")
    }
}
