import XCTest

/// The stage (YUI-13): a workout opens full screen, swipes away with the timer
/// still running in a pill, comes back from the pill, and closes with the X.
/// Runs on the demo account, no network. Screenshots go to `TEST_RUNNER_YUI_SHOTS`
/// when set, and always into the result bundle.
final class StageTests: XCTestCase {
    static let reply = [
        "say Tabata time. Eight rounds, 20 on and 10 off.",
        "timer@hiit 20/10x8 Tabata +auto",
        "ask Log it when you are done?",
    ].joined(separator: "\\n")

    func testWorkoutGoesFullScreenSwipesAwayAndComesBack() throws {
        try run(appearance: "light", agent: "coach")
    }

    func testDark() throws {
        try run(appearance: "dark", agent: "wizard")
    }

    /// Coach prefers full screen (style screen=full): the whole reply goes up.
    /// Wizard has no preference: only the workout does, the rest stays in the chat.
    private func run(appearance: String, agent: String) throws {
        let shots = ProcessInfo.processInfo.environment["YUI_SHOTS"].map { URL(fileURLWithPath: $0) }
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            if let shots { try? png.write(to: shots.appending(path: "\(appearance)-\(agent)-\(name).png")) }
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = "\(appearance)-\(agent)-\(name)"
            a.lifetime = .keepAlways
            add(a)
        }

        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", agent, "-appearance", appearance,
                               "-yuiThemeDemo", Self.reply]
        app.launch()

        // The reply streams in and the workout takes the whole screen.
        let close = app.buttons["Close full screen"]
        XCTAssertTrue(close.waitForExistence(timeout: 15), "the stage never opened")
        XCTAssertTrue(close.isHittable)
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5), "the +auto timer is not running")
        sleep(2)
        shot("1-stage-open")

        // Swipe down: back to the chat, the timer is a pill and keeps running.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        let pill = app.buttons["Open Tabata full screen"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "no pill in the chat")
        XCTAssertFalse(close.isHittable, "the stage did not go away")
        sleep(1)
        shot("2-swiped-away")
        sleep(3)
        shot("3-still-running")

        // Tap the pill: the stage is back, the same timer still running.
        pill.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        sleep(1)
        XCTAssertTrue(close.isHittable, "the pill did not reopen the stage")
        XCTAssertTrue(app.buttons["Pause"].exists, "the timer stopped while the stage was away")
        shot("4-reopened")

        // The X closes it too.
        close.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 4), .completed, "the X did not close the stage")
        shot("5-closed-with-x")
    }
}
