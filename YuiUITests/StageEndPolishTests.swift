import XCTest

/// Stage polish batch (TestFlight AKh8806F, ANAgZn8F, AC1AzxH4): the question at the top shows up to
/// six lines, the mic stays on the last page with a quiet Back home under the content, and Type your
/// own is a roomy field. Screenshots go to `YUI_SHOTS` when set, and always into the result bundle.
final class StageEndPolishTests: XCTestCase {
    private let long = "Can you look at the OpenRouter guide on community integrations and tell me whether it changes how Yui should route its models, what we would have to change in the shim, and whether it is worth doing before the next release goes out to everyone on TestFlight this week"

    func testQuestionShowsSixLines() throws {
        let app = launch("light")
        send(app, long)
        let you = app.descendants(matching: .any)["stage-you"].firstMatch
        XCTAssertTrue(you.waitForExistence(timeout: 15), "no question at the top")
        sleep(1)
        shot("1-question", "light")
        // One caption line is about 16pt; a question that was cut to one line is far under 60.
        XCTAssertGreaterThan(you.frame.height, 60, "the question is still cut to one or two lines")
        XCTAssertLessThan(you.frame.height, 130, "the question runs past six lines")
    }

    func testMicStaysAndBackHomeIsQuiet() throws {
        let app = launch("dark")
        send(app, "Plan it")
        let home = app.buttons["stage-home"]
        toQuestions(app)
        XCTAssertTrue(home.waitForExistence(timeout: 8), "no Back home on the last page")
        let mic = app.buttons["stage-mic"]
        shot("2-last-page-before", "dark")
        XCTAssertTrue(mic.exists, "the mic left the bar on the last page")
        XCTAssertLessThanOrEqual(home.frame.maxY, mic.frame.minY, "Back home is not under the content")
        XCTAssertLessThan(home.frame.height, 50, "Back home is not quiet")
        shot("2-last-page", "dark")
    }

    func testTypeYourOwnIsRoomy() throws {
        let app = launch("light")
        send(app, "Plan it")
        let own = app.buttons["Type your own"]
        toQuestions(app)
        XCTAssertTrue(own.waitForExistence(timeout: 8), "no Type your own")
        own.tap()
        sleep(1)
        shot("3-type-your-own-open", "light")
        let field = app.textFields["other-field"].exists ? app.textFields["other-field"] : app.textViews["other-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no field")
        XCTAssertGreaterThanOrEqual(field.frame.height, 60, "the field is a thin pill (was 22)")
        XCTAssertGreaterThan(field.frame.width, 200)
        field.tap()
        field.typeText("Ship it on Friday, but only if the vault card is done and the tests are green.")
        shot("3-type-your-own", "light")
    }

    /// A long typed answer stays whole once added: a wrapping box, not a capsule that clips it (AIUAO8VH).
    func testLongOwnAnswerStaysVisible() throws {
        let app = launch("dark")
        send(app, "Plan it")
        toQuestions(app)
        app.buttons["Type your own"].tap()
        let field = app.textFields["other-field"].exists ? app.textFields["other-field"] : app.textViews["other-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let words = "Don't spend any money, just hook up the API's. I'll test it for you later. I want her to be able to add their API keys and use it, and we should just trust that it works."
        field.typeText(words)
        shot("4-long-typing", "dark")
        app.buttons["other-add"].tap()
        sleep(1)
        shot("4-long-added", "dark")
        let pill = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Don't spend any money")).firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "the long answer is not on screen whole")
        XCTAssertGreaterThan(pill.frame.height, 90, "the long answer is still one clipped line")
        XCTAssertLessThanOrEqual(pill.frame.maxX, app.frame.maxX, "the long answer runs off the screen")
    }

    /// The trash is its own target: the mic does not turn into it, and only letting go over it cancels.
    func testTrashIsItsOwnTarget() throws {
        let app = launch("light", extra: ["-yuiPTTFake", "Cancel this one"])
        let mic = app.buttons["stage-mic"]
        XCTAssertTrue(mic.waitForExistence(timeout: 15), "no mic")
        let from = mic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // Held over the trash: it is a separate target and the mic is still a mic.
        from.press(forDuration: 1.0, thenDragTo: from.withOffset(CGVector(dx: -140, dy: 0)), withVelocity: .slow, thenHoldForDuration: 1.5)
        sleep(1)
        XCTAssertFalse(app.staticTexts["Cancel this one"].exists, "a recording let go over the trash was sent")
    }

    /// Read through to the questions, the last page.
    private func toQuestions(_ app: XCUIApplication) {
        let questions = app.descendants(matching: .any)["stage-questions"]
        for _ in 0..<6 where !questions.waitForExistence(timeout: 4) {
            if app.buttons["stage-next"].exists { app.buttons["stage-next"].tap() }
        }
        XCTAssertTrue(questions.exists, "no questions screen")
        sleep(1)
        shot("0-questions", "\(app.debugDescription.contains("Type your own") ? "seen" : "unseen")")
    }

    private func launch(_ appearance: String, extra: [String] = []) -> XCUIApplication {
        let reply = [
            "Two things.",
            "plan \"Before I go\"",
            "page \"Findings\" body=\"The guide changes nothing for routing.\"",
            "choose \"When do we ship?\" Friday|Monday +other",
            "end",
        ].joined(separator: "\\n")
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "yui",
                               "-appearance", appearance, "-yuiDemoReply", reply,
                               "-yuiDemoPickupAfter", "0.5", "-yuiDemoReplyAfter", "6"] + extra
        app.launch()
        return app
    }

    private func send(_ app: XCUIApplication, _ words: String) {
        XCTAssertTrue(app.buttons["stage-type"].waitForExistence(timeout: 15), "no stage")
        app.buttons["stage-type"].tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(words)
        app.buttons["stage-send-text"].tap()
    }

    private func shot(_ name: String, _ appearance: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "stage-polish-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "stage-polish-\(appearance)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }
}
