import XCTest

/// Copy any part of a message (TestFlight feedback AG9JzU4LeWl-TFeKWftiFIE):
/// hold an agent bubble, tap Select text, and its words open read-only.
/// Demo account, no network. `TEST_RUNNER_YUI_SHOTS=<dir>` saves screenshots.
final class SelectTextTests: XCTestCase {
    private let words = "Want me to set up Saturday? Squats 5x5 at 185, then a 20 minute tabata, done by 10."

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
    }

    private func check(_ appearance: String) {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiReactDemo", "bar", "-appearance", appearance]
        app.launch()

        // The held bubble's menu: Copy, then Select text.
        let select = app.buttons["react-select"]
        XCTAssertTrue(select.waitForExistence(timeout: 20), "no Select text in the hold menu")
        XCTAssertTrue(app.buttons["react-copy"].exists, "Copy left the hold menu")
        sleep(1)
        shot("select-menu-\(appearance)")
        select.tap()

        // The words, whole, in a view you can select in but not type in.
        let text = app.textViews["select-text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5), "Select text never opened")
        XCTAssertEqual(text.value as? String, words)
        XCTAssertFalse(app.buttons["react-select"].exists, "the hold menu stayed up under the sheet")
        text.tap()
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 1.5), "a keyboard came up: it is editable")
        text.press(forDuration: 1.0)
        sleep(1)
        shot("select-sheet-\(appearance)")

        // Done closes it; the chat and its bubble are still there.
        app.buttons["Done"].tap()
        XCTAssertTrue(text.waitForNonExistence(timeout: 5), "Done did not close it")
        XCTAssertTrue(app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Want me to set up Saturday")).firstMatch.exists)
    }

    func testSelectTextLight() { check("light") }
    func testSelectTextDark() { check("dark") }
}
