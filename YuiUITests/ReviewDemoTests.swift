import XCTest

/// App Review path (YUI-27): sign in with the demo code from the review notes,
/// say hi to the Demo agent, tap its first screen, then Settings > Help and
/// feedback. The demo agent must be running (hermes-plugin/demo_agent.py).
/// The code comes from the environment and never lands in the repo:
///
///   TEST_RUNNER_YUI_REVIEW_CODE=<code> TEST_RUNNER_YUI_SHOTS=/tmp/shots \
///     xcodebuild test -scheme Yui -destination '...' -only-testing:YuiUITests/ReviewDemoTests
final class ReviewDemoTests: XCTestCase {
    func testDemoCodeToDemoAgentScreen() throws {
        let env = ProcessInfo.processInfo.environment
        guard let code = env["YUI_REVIEW_CODE"], let dir = env["YUI_SHOTS"] else {
            throw XCTSkip("set TEST_RUNNER_YUI_REVIEW_CODE and TEST_RUNNER_YUI_SHOTS")
        }
        let shots = URL(fileURLWithPath: dir)
        func shot(_ name: String) {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: "\(name).png"))
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        let app = XCUIApplication()
        app.launchArguments = ["-yuiSignedOut", "-appearance", env["YUI_APPEARANCE"] ?? "light"]
        app.launch()

        let demo = app.buttons["Demo code"]
        XCTAssertTrue(demo.waitForExistence(timeout: 20), "no Demo code link on sign in")
        XCTAssertTrue(app.buttons["Sign in with Apple"].exists || app.buttons.matching(NSPredicate(format: "label CONTAINS 'Apple'")).count > 0)
        sleep(1)
        shot("01-sign-in")
        demo.tap()

        let field = app.textFields["reviewCode"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "code sheet did not open")
        field.typeText("WRONG-CODE")
        app.buttons["Sign in"].tap()
        XCTAssertTrue(app.staticTexts["That code didn't work. Check it and try again."].waitForExistence(timeout: 15),
                      "a wrong code was not refused")
        field.tap()
        field.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        field.typeText(code)
        sleep(1)
        shot("02-demo-code")
        app.buttons["Sign in"].tap()

        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }
        let input = app.textFields["Say something nice"]
        XCTAssertTrue(input.waitForExistence(timeout: 30), "no thread after the demo sign in")
        input.tap()
        input.typeText("hi")
        app.buttons["Send"].tap()

        let workout = app.buttons["Workout"].firstMatch
        XCTAssertTrue(workout.waitForExistence(timeout: 30), "Demo never answered")
        sleep(2)
        shot("03-demo-answers")
        workout.tap()

        let gear = app.buttons["Dumbbells"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 30), "the tap got no next screen")
        sleep(2)
        shot("04-next-screen")

        app.buttons["Settings"].firstMatch.tap()
        let help = app.staticTexts["Help and feedback"]
        XCTAssertTrue(help.waitForExistence(timeout: 10), "no Help and feedback in Settings")
        for _ in 0..<4 where !help.isHittable { app.scrollViews.firstMatch.swipeUp() }
        app.scrollViews.firstMatch.swipeUp()
        sleep(1)
        XCTAssertTrue(app.links["Email us"].exists || app.buttons["Email us"].exists, "no Email us link")
        XCTAssertTrue(app.staticTexts["Demo account"].exists, "account card does not say Demo account")
        shot("05-settings-help")
    }
}
