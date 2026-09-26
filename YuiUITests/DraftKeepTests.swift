import XCTest

/// Half-typed words stay (TestFlight feedback AK-9fNEZU, 2026-09-26: "I was writing
/// in the text box and then a new answer came in and took over the screen with a
/// full screen. But then when I came back my query was lost"). Demo account, no
/// network. `YUI_SHOTS=<dir>` saves screenshots.
final class DraftKeepTests: XCTestCase {
    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "draft-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "draft-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func composer(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["composer"].firstMatch
    }

    private func words(_ e: XCUIElement) -> String { (e.value as? String) ?? "" }

    private func launch(_ extra: [String] = [], reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "wizard", "-appearance", "dark"]
            + (reset ? [] : ["-yuiDraftsKeep"]) + extra
        app.launch()
        return app
    }

    /// The agent's answer opens full screen while the person is typing. Closing it
    /// gives the chat back with every word still in the field.
    func testAnAgentFullScreenKeepsTheDraft() throws {
        let app = launch(["-yuiThemeDemo", StageTests.reply, "-yuiDemoPrompt", "Workout?", "-yuiDemoDelay", "8"])
        let input = composer(app)
        XCTAssertTrue(input.waitForExistence(timeout: 10), "no composer")
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the keyboard never came up")
        input.typeText("How long is the rest between")
        XCTAssertFalse(app.buttons["Close full screen"].exists, "the full screen opened before the typing")
        shot("1-typing")

        let close = app.buttons["Close full screen"]
        XCTAssertTrue(close.waitForExistence(timeout: 15), "the agent's full screen never opened")
        sleep(1)
        shot("2-stage")
        close.tap()
        let down = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [down], timeout: 4), .completed, "the X did not close the stage")
        sleep(1)
        shot("3-back")
        XCTAssertEqual(words(input), "How long is the rest between", "the draft went with the full screen")

        // Typing picks up where it left off (a tap at the end of the words).
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        input.typeText(" rounds")
        XCTAssertEqual(words(input), "How long is the rest between rounds")
    }

    /// Each agent keeps its own draft; a relaunch brings it back; sending clears it.
    func testDraftsArePerAgentAndSurviveARelaunch() throws {
        var app = launch()
        var input = composer(app)
        XCTAssertTrue(input.waitForExistence(timeout: 10), "no composer")
        input.tap()
        input.typeText("Note for the wizard")

        // Another agent: its own empty field.
        app.terminate()
        app = launch(["-yuiAgent", "penny"], reset: false)
        input = composer(app)
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertFalse(words(input).contains("wizard"), "one agent's draft showed in another's thread")

        // Back to the wizard, after a relaunch: the words are there.
        app.terminate()
        app = launch(reset: false)
        input = composer(app)
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertEqual(words(input), "Note for the wizard", "the draft did not survive a relaunch")
        shot("4-relaunch")

        // Sent: gone for good.
        input.tap()
        app.buttons["Send"].tap()
        sleep(1)
        app.terminate()
        app = launch(reset: false)
        input = composer(app)
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertFalse(words(input).contains("Note for the wizard"), "a sent draft came back")
    }
}
