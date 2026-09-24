import XCTest

/// First run on a brand-new account (YUI-25): no agents, add one, pair it from
/// the host, say hi, get the first screen back. The host side (pairing with the
/// code, the agent's reply) is played by the driver script, which reads the code
/// this test writes to `YUI_SHOTS/code`. Throwaway accounts only, a FRESH refresh
/// token per run (a spent one signs out every device on the account):
///
///   TEST_RUNNER_YUI_RT=<refresh token> TEST_RUNNER_YUI_USER=<uuid> TEST_RUNNER_YUI_SHOTS=/tmp/shots \
///     xcodebuild test -scheme Yui -destination '...' -only-testing:YuiUITests/FirstRunTests
final class FirstRunTests: XCTestCase {
    func testSignInToFirstAgentScreen() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rt = env["YUI_RT"], let user = env["YUI_USER"], let dir = env["YUI_SHOTS"] else {
            throw XCTSkip("set TEST_RUNNER_YUI_RT, TEST_RUNNER_YUI_USER and TEST_RUNNER_YUI_SHOTS")
        }
        let shots = URL(fileURLWithPath: dir)
        func shot(_ name: String) {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: "\(name).png"))
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func allowNotifications() {
            let allow = springboard.buttons["Allow"]
            if allow.waitForExistence(timeout: 3) { allow.tap() }
        }

        let app = XCUIApplication()
        app.launchArguments = ["-yuiRefreshToken", rt, "-yuiUserID", user, "-appearance", env["YUI_APPEARANCE"] ?? "light"]
        app.launch()

        // A new account has no agents: the chat says how to connect one, no input bar.
        let addFirst = app.buttons["Add your first agent"]
        XCTAssertTrue(addFirst.waitForExistence(timeout: 20), "no first-run screen")
        XCTAssertFalse(app.textFields["Say something nice"].exists, "input bar shown with no agent")
        XCTAssertFalse(springboard.alerts.firstMatch.exists, "asked for notifications before any agent")
        sleep(2)
        shot("01-no-agents")
        addFirst.tap()

        let name = app.textFields.matching(NSPredicate(format: "placeholderValue == %@ OR label == %@", "Name, like Nova", "Name, like Nova")).firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 10), "add agent did not open")
        sleep(1)
        name.tap()
        name.typeText("Nova")
        sleep(1)
        shot("02-add-agent")
        app.buttons["Get a pairing code"].tap()

        let code = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Pairing code")).firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 20), "no pairing code")
        allowNotifications()
        let digits = code.label.filter(\.isNumber)
        XCTAssertEqual(digits.count, 6)
        XCTAssertTrue(app.staticTexts["hermes yui pair \(digits)"].exists, "pair command missing the code")
        XCTAssertTrue(app.staticTexts["hermes gateway restart"].exists, "restart step missing")
        sleep(2)
        shot("03-pairing-code")
        // Hand the code to the host.
        try digits.write(to: shots.appending(path: "code"), atomically: true, encoding: .utf8)

        let sayHi = app.buttons["Say hi to Nova"]
        XCTAssertTrue(sayHi.waitForExistence(timeout: 120), "never connected")
        sleep(2)
        shot("04-connected")
        sayHi.tap()

        let hi = app.buttons["Hi!"]
        XCTAssertTrue(hi.waitForExistence(timeout: 15), "no starter in the new thread")
        sleep(2)
        shot("05-thread")
        hi.tap()

        let reply = app.buttons["Plan my day"].firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 90), "the first reply never arrived")
        sleep(3)
        shot("06-first-reply")
    }
}
