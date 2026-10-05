import XCTest

/// Chris, TestFlight build 522, Arnold's thread: "that start button doesn't work at all", and the
/// runner played inside the drawer's Review tab. Start on Today's workout opens the runner full
/// screen; a Review tap never plays it inside the drawer. Demo account, no network: the stand-in
/// Arnold answers a tap with the plan the runtime sends. `YUI_SHOTS=<dir>` saves screenshots.
final class WorkoutStartFromScreenTests: XCTestCase {
    /// As runtime/src/workouts.ts runnerLines sends it. No apostrophes (launch args are plists).
    private static let runner = [
        "Full body A. 2 moves, one set at a time.",
        "```yui",
        "plan@wk-20261005-mon Full-body-A submit=\"Finish workout\"",
        "page Full-body-A body=\"2 moves, about 20 minutes. Rest about 60 seconds between sets.\" points=\"Goblet squat 2x10\"|\"Plank 2x30s\"",
        "pick@e1-sets \"Goblet squat: sets done\" \"Set 1\"|\"Set 2\"|Skip tag=\"1 of 2\" title=\"Goblet squat\" body=\"Target 2 x 10.\" cue=\"Brace. Slow down.\" work=32",
        "slide@e1-reps \"Goblet squat: reps per set\" 1-30 value=10",
        "slide@e1-lb \"Goblet squat: weight in lb\" 0-300 value=20 step=5 unit=lb",
        "pick@e2-sets \"Plank: sets done\" \"Set 1\"|\"Set 2\"|Skip tag=\"2 of 2\" title=Plank body=\"Target 2 x 30s.\" cue=\"Straight line. Squeeze everything.\" work=30",
        "slide@e2-secs \"Plank: seconds per set\" 5-180 value=30 step=5",
        "choose@feel \"How did it feel?\" Easy|\"Just right\"|Hard",
        "```",
    ].joined(separator: "\\n")

    private var appearance = "dark"

    func testStartOpensRunnerDark() { start() }
    func testStartOpensRunnerLight() { appearance = "light"; start() }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "start-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "start-\(appearance)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func launch(reply: String = runner) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoHome", "-yuiAgent", "arnold",
                               "-appearance", appearance, "-yuiDemoReply", reply, "-yuiDemoReplyTaps", "-yuiDemoDelay", "0.5",
                               "-yuiRunnerReset", "-yuiRunnerFast"]
        app.launch()
        return app
    }

    /// Today's workout, a swipe or two from the home: Start is the card's button.
    private func tapStart(_ app: XCUIApplication) {
        XCTAssertTrue(app.descendants(matching: .any)["stage-home"].waitForExistence(timeout: 15), "no Arnold home")
        let today = app.descendants(matching: .any)["stage-screen-3"]
        for _ in 0..<4 where !today.exists || !today.isHittable { app.swipeLeft(); usleep(600_000) }
        XCTAssertTrue(today.waitForExistence(timeout: 5), "no Today's workout screen")
        shot("1-today")
        let go = today.buttons["Start"]
        XCTAssertTrue(go.waitForExistence(timeout: 3), "no Start button on Today's workout")
        go.tap()
    }

    /// An answer that is not a runner (no split yet): Start comes back to where it shows, not a dead screen.
    func testAnAnswerToStartIsNotLeftOffScreen() {
        let app = launch(reply: "say Build your split first, then I will run it with you.")
        tapStart(app)
        XCTAssertTrue(app.staticTexts["Build your split first, then I will run it with you."].waitForExistence(timeout: 10),
                      "Start answered, and the answer was out of sight on the screen")
        XCTAssertFalse(app.descendants(matching: .any)["stage-screen-3"].isHittable, "still on the screen after Start")
        shot("2-answer")
    }

    /// A workout in Review opens the runner full screen, closing the drawer; it never plays inside it.
    func testReviewTapOpensTheRunnerFullScreen() {
        let app = launch()
        tapStart(app)
        let clock = app.staticTexts["session-clock"]
        let ok = clock.waitForExistence(timeout: 15)
        shot("2b-runner")
        XCTAssertTrue(ok, "the workout did not open full screen")
        (app.buttons["Close"].exists ? app.buttons["Close"] : app.buttons["Close full screen"]).tap()
        let menu = app.buttons["stage-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8), "no stage after closing the runner")
        menu.tap()
        XCTAssertTrue(app.buttons["drawer-close"].waitForExistence(timeout: 5), "the drawer did not open")
        app.buttons["drawer-tab-review"].tap()
        let row = app.buttons["review-wk-20261005-mon"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the workout is not waiting in Review")
        shot("3-review")
        XCTAssertFalse(app.staticTexts["session-phase"].firstMatch.isHittable, "the runner is already inside the drawer")
        row.tap()
        XCTAssertTrue(app.staticTexts["session-phase"].waitForExistence(timeout: 8), "a Review tap did not open the runner")
        XCTAssertFalse(app.buttons["drawer-close"].exists, "the runner opened inside the drawer")
        shot("4-review-runner")
    }

    private func start() {
        let app = launch()
        tapStart(app)
        // The runner is the session, no overview with a second Start first.
        XCTAssertTrue(app.staticTexts["session-clock"].waitForExistence(timeout: 10), "Start did not open the runner")
        XCTAssertFalse(app.buttons["runner-start"].exists, "an overview with a second Start came first")
        XCTAssertTrue(app.staticTexts["session-move"].exists)
        shot("2-runner")
        // The set ends; the app asks reps, then the rest counts down.
        XCTAssertTrue(app.buttons["session-log-done"].waitForExistence(timeout: 14), "the set did not ask what was done")
        shot("3-log")
        app.buttons["session-log-done"].tap()
        shot("4-rest")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["session-log-done"])
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 8), .completed, "the log did not move on to the rest")
    }
}
