import XCTest

/// Stop on the live backend (YUI-190). Driven by supabase/tests/native_stop_live.py, which makes
/// a throwaway account, checks the database as this goes (the stop row, the turn handled, no
/// answer), and deletes the account after. The person asks hosted Yui for something long, taps
/// the stop square, and the late answer never lands.
///
///   TEST_RUNNER_YUI_RT=<refresh token> TEST_RUNNER_YUI_USER=<uuid> TEST_RUNNER_YUI_AGENT=<agent id> \
///   TEST_RUNNER_YUI_SHOTS=/tmp/shots xcodebuild test ... -only-testing:YuiUITests/StopLiveTests
final class StopLiveTests: XCTestCase {
    func testStopAHostedTurn() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rt = env["YUI_RT"], let user = env["YUI_USER"], let agent = env["YUI_AGENT"], let dir = env["YUI_SHOTS"] else {
            throw XCTSkip("set TEST_RUNNER_YUI_RT, TEST_RUNNER_YUI_USER, TEST_RUNNER_YUI_AGENT and TEST_RUNNER_YUI_SHOTS")
        }
        let shots = URL(fileURLWithPath: dir)
        func shot(_ name: String) {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: "\(name).png"))
        }
        func wait(for flag: String, _ seconds: TimeInterval) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if FileManager.default.fileExists(atPath: shots.appending(path: flag).path) { return true }; sleep(1) }
            return false
        }
        let app = XCUIApplication()
        app.launchArguments = ["-yuiRefreshToken", rt, "-yuiUserID", user, "-selectedAgent", agent, "-yuiStageFirst", "YES",
                               "-appearance", env["YUI_APPEARANCE"] ?? "light"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Allow"].waitForExistence(timeout: 8) { springboard.buttons["Allow"].tap() }

        let type = app.buttons["stage-type"]
        XCTAssertTrue(type.waitForExistence(timeout: 30), "the stage never came up")
        type.tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Plan every meal for the next seven days, with recipes and a full grocery list")
        app.buttons["stage-send-text"].tap()

        let stop = app.buttons["stage-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "no stop square while hosted Yui works")
        XCTAssertTrue(wait(for: "picked", 60), "the runtime never picked the message up")
        shot("live-1-working")
        stop.tap()
        XCTAssertTrue(app.descendants(matching: .any)["stage-stopped"].firstMatch.waitForExistence(timeout: 5), "the stage did not stop")
        XCTAssertTrue(app.buttons["stage-mic"].waitForExistence(timeout: 5), "the mic did not come back")
        try? "".write(to: shots.appending(path: "stopped"), atomically: true, encoding: .utf8)

        // The driver watches the database for 45 seconds: no answer may land.
        XCTAssertTrue(wait(for: "checked", 120), "the driver never finished its check")
        XCTAssertTrue(app.descendants(matching: .any)["stage-stopped"].firstMatch.exists, "an answer replaced Stopped")
        shot("live-2-stopped")
        app.buttons["stage-record"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["stopped-note"].firstMatch.waitForExistence(timeout: 5), "no Stopped in the record")
        sleep(1)
        shot("live-3-record")
    }
}
