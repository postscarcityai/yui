import XCTest

/// The composer after Send (TestFlight feedback APthnqcdHvqEP): the words leave
/// the field, land in the thread once, and the keyboard stays up for the next one.
/// Demo account, no network. `TEST_RUNNER_YUI_SHOTS=<dir>` saves screenshots.
final class ComposerTests: XCTestCase {
    private let placeholder = "Say something nice"

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemo", "-appearance", "dark"]
        app.launch()
        return app
    }

    private func field(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["composer"].firstMatch
    }

    /// What the field draws: its value, or nothing when it shows the placeholder.
    private func shown(_ e: XCUIElement) -> String {
        let v = (e.value as? String) ?? ""
        return v == placeholder ? "" : v
    }

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
    }

    func testSendClearsTheField() {
        let app = launch()
        let input = field(app)
        XCTAssertTrue(input.waitForExistence(timeout: 20), "no composer")
        input.tap()
        let text = "Hey there, what do you know about me?"
        input.typeText(text)
        XCTAssertEqual(shown(input), text)
        shot("01-typed")

        app.buttons["Send"].tap()
        shot("02a-lifting")
        let sent = app.staticTexts[text]
        XCTAssertTrue(sent.waitForExistence(timeout: 5), "the message never reached the thread")
        shot("02-sent")

        let after = field(app)
        XCTAssertEqual(shown(after), "", "the sent words are still in the composer")
        XCTAssertFalse(app.buttons["Send"].exists, "Send is up on an empty composer")
        XCTAssertTrue(app.descendants(matching: .any)["talk"].exists, "an empty composer shows the mic")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", text)).count, 1, "sent twice")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the keyboard went away after Send")

        // The next message goes the same way, straight from the kept keyboard.
        after.typeText("And another")
        XCTAssertEqual(shown(field(app)), "And another")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts["And another"].waitForExistence(timeout: 5))
        XCTAssertEqual(shown(field(app)), "", "the second message stayed in the composer")
        sleep(1)
        shot("03-second-sent")
    }

    /// Send tapped with an autocorrection still pending on the last word: the
    /// keyboard commits it after the field is emptied.
    func testSendWithAPendingCorrectionClears() {
        let app = launch()
        let input = field(app)
        XCTAssertTrue(input.waitForExistence(timeout: 20), "no composer")
        input.tap()
        input.typeText("What do you knwo abotu")
        shot("04-pending-correction")
        app.buttons["Send"].tap()
        func mine() -> XCUIElementQuery {
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "What do you"))
        }
        XCTAssertTrue(mine().firstMatch.waitForExistence(timeout: 5),
                      "the message never reached the thread")
        sleep(1)
        shot("05-pending-correction-sent")
        XCTAssertEqual(shown(field(app)), "", "the keyboard put the sent words back in the composer")
        XCTAssertEqual(mine().count, 1, "sent twice")
    }
}
