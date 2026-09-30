import XCTest

/// t_82dc3a4b: the system photo picker opened from the composer, for the before/after shot of its limit line.
final class PickerShotTests: XCTestCase {
    func testPickerShot() throws {
        guard let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] else { throw XCTSkip("driver only") }
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemo", "-appearance", "dark"]
        app.launch()
        let attach = app.buttons["attach"]
        XCTAssertTrue(attach.waitForExistence(timeout: 20))
        attach.tap()
        app.buttons["Photo library"].tap()
        sleep(6)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "picker.png"))
    }
}
