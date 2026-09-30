import XCTest

/// The last page keeps the mic (YUI-208, Chris: "at this final screen I will probably want to use the
/// microphone ... if I make the selections and then push the microphone to say something, I want them
/// all to go in together as one answer"). Back home and New chat sit on the page under Send; typed or
/// spoken words with picks waiting go as ONE event, the plan plus `said`.
/// Screenshots go to `YUI_SHOTS` when set, and always into the result bundle.
final class StageLastPageTests: XCTestCase {
    func testBackHomeAndNewChatSitOnThePageLight() throws { try onThePage("light") }
    func testBackHomeAndNewChatSitOnThePageDark() throws { try onThePage("dark") }

    private func onThePage(_ appearance: String) throws {
        let (app, _) = launch(appearance)
        try toQuestions(app)
        let home = app.buttons["stage-home"], fresh = app.buttons["stage-page-new-chat"], mic = app.buttons["stage-mic"]
        XCTAssertTrue(home.waitForExistence(timeout: 5), "no Back home on the page")
        XCTAssertTrue(fresh.exists, "no New chat on the page")
        XCTAssertTrue(mic.exists, "the mic left the bar")
        XCTAssertLessThan(home.frame.maxX, fresh.frame.minX + 1, "Back home and New chat are not side by side")
        XCTAssertLessThanOrEqual(home.frame.maxY, mic.frame.minY, "the buttons sit under the content, above the bar")
        shot("1-last-page", appearance)
    }

    /// A pick, then words typed through T: one plan event with `said`, one message in the record.
    func testTypedWordsGoWithThePicks() throws {
        let (app, log) = launch("light")
        try toQuestions(app)
        app.buttons["Friday"].tap()
        app.buttons["stage-type"].tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Also, bring the vault card")
        shot("2-typed", "light")
        app.buttons["stage-send-text"].tap()
        sleep(2)
        let events = try events(log)
        XCTAssertEqual(events.count, 1, "the picks and the words went as \(events.count) messages: \(events)")
        XCTAssertTrue(events[0].contains("\"said\":\"Also, bring the vault card\""), "the words are not in the answer: \(events[0])")
        XCTAssertTrue(events[0].contains("Friday"), "the pick is not in the answer: \(events[0])")
        XCTAssertTrue(events[0].contains("\"preset\":\"plan\""), "not the plan event: \(events[0])")
        shot("3-sent", "light")
    }

    /// The same by voice: a held mic with a pick waiting.
    func testSpokenWordsGoWithThePicks() throws {
        let (app, log) = launch("dark", extra: ["-yuiPTTFake", "Also bring the vault card"])
        try toQuestions(app)
        app.buttons["Friday"].tap()
        let mic = app.buttons["stage-mic"]
        let from = mic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 1.5)
        sleep(3)
        shot("4-spoken-sent", "dark")
        let events = try events(log)
        XCTAssertEqual(events.count, 1, "the picks and the words went as \(events.count) messages: \(events)")
        XCTAssertTrue(events[0].contains("\"said\":\"Also bring the vault card\""), "the words are not in the answer: \(events[0])")
    }

    /// With nothing picked the words are a message of their own, as before.
    func testWordsAloneGoAlone() throws {
        let (app, log) = launch("light")
        try toQuestions(app)
        app.buttons["stage-type"].tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Something unrelated")
        app.buttons["stage-send-text"].tap()
        sleep(2)
        XCTAssertFalse((try? events(log))?.contains { $0.contains("\"preset\":\"plan\"") } ?? false, "a plan went with nothing picked")
    }

    private func events(_ log: String) throws -> [String] {
        let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    private func toQuestions(_ app: XCUIApplication) throws {
        XCTAssertTrue(app.buttons["stage-type"].waitForExistence(timeout: 15), "no stage")
        app.buttons["stage-type"].tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Plan it")
        app.buttons["stage-send-text"].tap()
        let questions = app.descendants(matching: .any)["stage-questions"]
        for _ in 0..<8 where !questions.waitForExistence(timeout: 4) {
            if app.buttons["stage-next"].exists { app.buttons["stage-next"].tap() }
        }
        XCTAssertTrue(questions.exists, "no questions screen")
        sleep(1)
    }

    private func launch(_ appearance: String, extra: [String] = []) -> (XCUIApplication, String) {
        let reply = [
            "Two things.",
            "plan \"Before I go\"",
            "page \"Findings\" body=\"The guide changes nothing for routing.\"",
            "choose \"When do we ship?\" Friday|Monday +other",
            "end",
        ].joined(separator: "\\n")
        let log = NSTemporaryDirectory() + "yui-208-\(UUID().uuidString).log"
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "yui",
                               "-appearance", appearance, "-yuiDemoReply", reply, "-yuiEventLog", log,
                               "-yuiDemoPickupAfter", "0.5", "-yuiDemoReplyAfter", "6"] + extra
        app.launch()
        return (app, log)
    }

    private func shot(_ name: String, _ appearance: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "stage-lastpage-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "stage-lastpage-\(appearance)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }
}
