import XCTest

/// A way out of every full-screen answer (YUI-195, TestFlight feedback: "I don't wanna take any
/// action. I don't want to burn any tokens so I need a default way to just cancel this and get
/// back to the home screen"). Close mid-plan, Back home at the end, pull the card down: each one
/// goes home and sends nothing (the record still holds one message of theirs and no working
/// state ever starts), and the plan opens again from its chip in the chat.
/// Screenshots go to `YUI_SHOTS` when set, and always into the result bundle.
final class StageCloseTests: XCTestCase {
    private let said = "OK, yeah go ahead and release that."

    func testCloseMidPlanLight() throws { try closeMidPlan(appearance: "light") }
    func testCloseMidPlanDark() throws { try closeMidPlan(appearance: "dark") }
    func testBackHomeAtTheEndLight() throws { try backHome(appearance: "light") }
    func testBackHomeAtTheEndDark() throws { try backHome(appearance: "dark") }
    func testPullDownToDismissLight() throws { try pullDown(appearance: "light") }
    func testPullDownToDismissDark() throws { try pullDown(appearance: "dark") }

    private func closeMidPlan(appearance: String) throws {
        let app = launch(appearance)
        try play(app)
        XCTAssertFalse(app.buttons["stage-home"].exists, "Back home belongs at the end, not on the first page")
        shot("1-mid-plan", appearance)
        app.buttons["stage-close"].tap()
        try assertHome(app)
        shot("2-home", appearance)
        try assertNothingSent(app)
        try assertReopens(app)
        shot("3-reopened", appearance)
    }

    private func backHome(appearance: String) throws {
        let app = launch(appearance)
        try play(app)
        for _ in 0..<3 { app.buttons["stage-next"].tap() }
        XCTAssertTrue(app.descendants(matching: .any)["stage-questions"].waitForExistence(timeout: 3), "no questions screen")
        let home = app.buttons["stage-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 3), "no Back home on the last page")
        let mic = app.buttons["stage-mic"]
        XCTAssertTrue(mic.exists, "the mic must stay on the last page")
        XCTAssertLessThanOrEqual(home.frame.maxY, mic.frame.minY, "Back home sits under the content, above the bar")
        XCTAssertFalse(app.buttons["stage-close"].exists, "one way out at the end, not two")
        shot("1-end", appearance)
        home.tap()
        try assertHome(app)
        XCTAssertTrue(app.buttons["stage-mic"].waitForExistence(timeout: 3), "the mic did not come back")
        shot("2-home", appearance)
        try assertNothingSent(app)
        try assertReopens(app)
    }

    private func pullDown(appearance: String) throws {
        let app = launch(appearance)
        try play(app)
        let stage = app.descendants(matching: .any)["stage-first"]
        // A short pull springs back: the answer stays.
        let top = stage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        top.press(forDuration: 0.05, thenDragTo: stage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.36)))
        sleep(1)
        XCTAssertTrue(app.descendants(matching: .any)["stage-segments"].exists, "a short pull closed the answer")
        // A long pull goes home.
        top.press(forDuration: 0.05, thenDragTo: stage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        try assertHome(app)
        shot("1-home", appearance)
        try assertNothingSent(app)
        try assertReopens(app)
    }

    // MARK: Steps

    private func play(_ app: XCUIApplication) throws {
        XCTAssertTrue(app.buttons["stage-type"].waitForExistence(timeout: 15), "no stage")
        app.buttons["stage-type"].tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(said)
        app.buttons["stage-send-text"].tap()
        let both = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'stage-segments' AND label == 'Part 1 of 2'")).firstMatch
        XCTAssertTrue(both.waitForExistence(timeout: 25), "the reply never grew to its two parts")
        XCTAssertTrue(app.buttons["stage-close"].waitForExistence(timeout: 3), "no close on the plan")
    }

    /// The agent's home: no answer on screen, and the greeting or its shortcuts in its place.
    private func assertHome(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) throws {
        let segments = app.descendants(matching: .any)["stage-segments"]
        for _ in 0..<50 where segments.exists { usleep(100_000) }
        XCTAssertFalse(segments.exists, "the answer is still up", file: file, line: line)
        XCTAssertFalse(app.descendants(matching: .any)["stage-questions"].exists, "the questions are still up", file: file, line: line)
        XCTAssertFalse(app.buttons["stage-close"].exists, "the close is still there at home", file: file, line: line)
        XCTAssertFalse(app.buttons["stage-home"].exists, "Back home is still there at home", file: file, line: line)
    }

    /// Nothing went out: the record holds their one message and the agent is not working.
    private func assertNothingSent(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(app.descendants(matching: .any)["stage-working"].exists, "closing started a turn", file: file, line: line)
        app.buttons["stage-record"].tap()
        XCTAssertTrue(app.buttons["back-to-stage"].waitForExistence(timeout: 5), "no record", file: file, line: line)
        let mine = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", said))
        XCTAssertEqual(mine.count, 1, "their message is not in the record exactly once", file: file, line: line)
        let bubbles = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'bubble-user'"))
        XCTAssertLessThanOrEqual(bubbles.count, 1, "closing sent something to the agent", file: file, line: line)
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'stopped'")).firstMatch.exists,
                       "closing was sent as a stop", file: file, line: line)
    }

    /// Nothing is lost: the chip in the record plays the reply again.
    private func assertReopens(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) throws {
        let chip = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Before I go")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "the plan has no chip in the record", file: file, line: line)
        chip.tap()
        XCTAssertTrue(app.descendants(matching: .any)["stage-first"].waitForExistence(timeout: 5), "the stage did not come back", file: file, line: line)
        XCTAssertTrue(app.descendants(matching: .any)["stage-questions"].waitForExistence(timeout: 5)
                      || app.descendants(matching: .any)["stage-segments"].waitForExistence(timeout: 5),
                      "the plan did not play again", file: file, line: line)
    }

    private func launch(_ appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "yui",
                               "-appearance", appearance, "-yuiDemoReply", StageFirstTests.releaseReply,
                               "-yuiDemoPickupAfter", "0.5", "-yuiDemoReplyAfter", "2"]
        app.launch()
        return app
    }

    private func shot(_ name: String, _ appearance: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "stage-close-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "stage-close-\(appearance)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }
}
