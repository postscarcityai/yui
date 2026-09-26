import XCTest

/// A full screen takes the keyboard with it (TestFlight feedback ACbsyYSZ,
/// 2026-09-26: "if I ever open a full screen, I need the keyboard to go away
/// automatically"). Type in the composer, open the stage: no keyboard. Close
/// it: the keyboard stays down. Demo account, no network, a fresh launch per run.
/// `YUI_SHOTS=<dir>` saves screenshots.
final class KeyboardStageTests: XCTestCase {
    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "keyboard-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "keyboard-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func noKeyboard(_ app: XCUIApplication, _ why: String) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 0"), object: app.keyboards)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 3), .completed, why)
    }

    func testOpeningTheStageDropsTheKeyboard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "wizard", "-appearance", "dark",
                               "-yuiThemeDemo", StageTests.reply]
        app.launch()

        // The workout opens on its own; swipe it away to get the chat back.
        let close = app.buttons["Close full screen"]
        XCTAssertTrue(close.waitForExistence(timeout: 15), "the stage never opened")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        let pill = app.buttons["Open Tabata full screen"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "no pill in the chat")

        // Typing: the keyboard is up.
        let input = app.descendants(matching: .any)["composer"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5), "no composer")
        input.tap()
        input.typeText("How long is the rest")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "the keyboard never came up")
        shot("1-typing")

        // Open the full screen: the keyboard goes with it.
        pill.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        noKeyboard(app, "the keyboard stayed up over the full screen")
        sleep(1)
        shot("2-stage-open")

        // Close it: back in the chat, the keyboard does not pop back up.
        close.tap()
        let down = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [down], timeout: 4), .completed, "the X did not close the stage")
        sleep(1)
        XCTAssertEqual(app.keyboards.count, 0, "closing the stage brought the keyboard back")
        shot("3-closed")

        // The words are still there, and a tap on the composer brings the keyboard back.
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "the composer no longer takes focus")
    }
}
