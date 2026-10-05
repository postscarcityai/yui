import XCTest

/// The tabs over a screen read what is on it, never "Screen N" (Chris, Oct 5).
/// Demo account, no network.
final class ScreenNameTabTests: XCTestCase {
    func testNoTabReadsScreen() throws {
        let reply = ["say Two pages.",
                     ">2 stat 1 \"Workouts this week\"",
                     ">3 timer 5m"].joined(separator: "\\n")
        let env = ProcessInfo.processInfo.environment
        let look = env["YUI_APPEARANCE"] ?? "dark"
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "yui",
                               "-appearance", look, "-yuiDemoReply", reply, "-yuiDemoPickupAfter", "0.5",
                               "-yuiDemoReplyAfter", "2"]
        app.launch()
        XCTAssertTrue(app.buttons["stage-type"].waitForExistence(timeout: 15), "no stage")
        app.buttons["stage-type"].tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Plan my week")
        app.buttons["stage-send-text"].tap()
        let two = app.buttons["screen-pill-2"]
        XCTAssertTrue(two.waitForExistence(timeout: 20), "no tab for page 2")
        XCTAssertTrue(app.buttons["screen-pill-3"].waitForExistence(timeout: 10), "no tab for page 3")
        for n in 2...3 {
            let label = app.buttons["screen-pill-\(n)"].label
            XCTAssertFalse(label.hasPrefix("Screen"), "tab \(n) reads \(label)")
        }
        XCTAssertEqual(app.buttons["screen-pill-2"].label, "Workouts this week")
        XCTAssertEqual(app.buttons["screen-pill-3"].label, "Timer")
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = env["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "screen-name-tabs-\(look).png"))
        }
    }
}
