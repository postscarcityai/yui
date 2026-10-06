import XCTest

/// Context and action on one screen (TestFlight Oct 5: two bare "Ship it?" with no word on WHAT ships,
/// "I need context and action on the same screen"). Each question on the stacked questions page carries the
/// line of its own reply that came right before it, directly above its buttons.
/// Screenshots go to `YUI_SHOTS` when set, and always into the result bundle.
final class StageQuestionContextTests: XCTestCase {
    func testEachQuestionShowsItsContextAboveItLight() throws { try aboveEachQuestion("light") }
    func testEachQuestionShowsItsContextAboveItDark() throws { try aboveEachQuestion("dark") }

    private func aboveEachQuestion(_ appearance: String) throws {
        let app = launch(appearance)
        XCTAssertTrue(app.buttons["stage-type"].waitForExistence(timeout: 15), "no stage")
        app.buttons["stage-type"].tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Status")
        app.buttons["stage-send-text"].tap()
        let questions = app.descendants(matching: .any)["stage-questions"]
        for _ in 0..<8 where !questions.waitForExistence(timeout: 4) {
            if app.buttons["stage-next"].exists { app.buttons["stage-next"].tap() }
        }
        XCTAssertTrue(questions.exists, "no questions screen")
        sleep(1)
        // The reply draws twice (the chat copy sits under the stage): count only what is on screen.
        let contexts = app.descendants(matching: .any).matching(identifier: "stage-question-context").allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertEqual(contexts.count, 2, "each of the two questions needs its context")
        let ships = questions.buttons.matching(identifier: "Ship it").allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertEqual(ships.count, 2)
        if contexts.count == 2, ships.count == 2 {
            XCTAssertLessThanOrEqual(contexts[0].frame.maxY, ships[0].frame.minY, "the first context is not above its buttons")
            XCTAssertLessThanOrEqual(ships[0].frame.maxY, contexts[1].frame.minY, "the second context is not between the questions")
            XCTAssertLessThanOrEqual(contexts[1].frame.maxY, ships[1].frame.minY, "the second context is not above its buttons")
        }
        XCTAssertTrue(app.staticTexts["Explainers draw every page."].exists || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Explainers'")).count > 0)
        shot("questions", appearance)
    }

    private func launch(_ appearance: String) -> XCUIApplication {
        let reply = [
            "say \"Explainers draw every page.\"",
            "choose \"Ship it?\" \"Ship it\"|\"Not yet\"|\"Show me more\"",
            "say \"Left drawer shows Done cards.\"",
            "choose \"Ship it?\" \"Ship it\"|\"Tweak it first\"|\"Not yet\"",
        ].joined(separator: "\\n")
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "yui",
                               "-appearance", appearance, "-yuiDemoReply", reply,
                               "-yuiDemoPickupAfter", "0.5", "-yuiDemoReplyAfter", "6"]
        app.launch()
        return app
    }

    private func shot(_ name: String, _ appearance: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "stage-question-context-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "stage-question-context-\(appearance)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }
}
