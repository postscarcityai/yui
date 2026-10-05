import XCTest

/// Chris, TestFlight (feedback AMEDGjyb, Oct 5): "I should be able to control the music from here. I
/// should be able to make edits on the Fly." The runner has a now-playing strip only while music plays,
/// and an edit sheet for the move on screen: swap it, change its sets, add a move after it, without
/// leaving the runner. Demo account, no network. `-yuiMusicFake` stands in a song; without it the
/// simulator plays nothing, so the strip is gone. `YUI_SHOTS=<dir>` saves screenshots.
final class WorkoutEditMusicTests: XCTestCase {
    /// As runtime/src/workouts.ts runnerLines sends it. No apostrophes (launch args are plists).
    private static let runner = [
        "Full body A. One move at a time.",
        "```yui",
        "plan@wk-20261005-mon Full-body-A submit=\"Finish workout\"",
        "page Full-body-A body=\"2 moves, about 20 minutes. Rest about 60 seconds between sets.\" points=\"Goblet squat 3x10\"|\"Plank 2x30s\"",
        "pick@e1-sets \"Goblet squat: sets done\" \"Set 1\"|\"Set 2\"|\"Set 3\"|Skip tag=\"1 of 2\" title=\"Goblet squat\" body=\"Target 3 x 10 at 20 lb.\" cue=\"Brace. Knees out. Drive up.\" work=40",
        "slide@e1-reps \"Goblet squat: reps per set\" 1-30 value=10",
        "slide@e1-lb \"Goblet squat: weight in lb\" 0-300 value=20 step=5 unit=lb",
        "pick@e2-sets \"Plank: sets done\" \"Set 1\"|\"Set 2\"|Skip tag=\"2 of 2\" title=Plank body=\"Target 2 x 30s.\" cue=\"Straight line. Squeeze everything.\" work=30",
        "slide@e2-secs \"Plank: seconds per set\" 5-180 value=30 step=5",
        "choose@feel \"How did it feel?\" Easy|\"Just right\"|Hard",
        "```",
    ].joined(separator: "\\n")

    private var appearance = "dark"

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "edit-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "edit-\(appearance)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func open(music: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoHome", "-yuiAgent", "arnold",
                               "-appearance", appearance, "-yuiDemoReply", Self.runner, "-yuiDemoReplyTaps", "-yuiDemoDelay", "0.5",
                               "-yuiRunnerReset"] + (music ? ["-yuiMusicFake"] : [])
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["stage-home"].waitForExistence(timeout: 15), "no Arnold home")
        let today = app.descendants(matching: .any)["stage-screen-3"]
        for _ in 0..<4 where !today.exists || !today.isHittable { app.swipeLeft(); usleep(600_000) }
        let go = today.buttons["Start"]
        XCTAssertTrue(go.waitForExistence(timeout: 5), "no Start button on Today's workout")
        go.tap()
        XCTAssertTrue(app.staticTexts["session-clock"].waitForExistence(timeout: 15), "Start did not open the runner")
        return app
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    /// Nothing playing (a simulator never is): no strip, no dead buttons.
    func testMusicStripIsGoneWhenNothingPlays() {
        let app = open(music: false)
        XCTAssertTrue(app.buttons["session-edit"].exists, "no edit button in the runner")
        XCTAssertFalse(any(app, "session-music").exists, "a music strip with nothing playing")
        XCTAssertFalse(app.buttons["session-music-play"].exists)
    }

    func testMusicAndEditsOnTheFlyDark() { musicAndEdits() }
    func testMusicAndEditsOnTheFlyLight() { appearance = "light"; musicAndEdits() }

    private func musicAndEdits() {
        let app = open(music: true)
        // The strip: the song, and its buttons act on it.
        let title = app.staticTexts["session-music-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "no music strip while music plays")
        XCTAssertEqual(title.label, "Midnight City")
        app.buttons["session-music-next"].tap()
        XCTAssertEqual(app.staticTexts["session-music-title"].label, "Harder, Better, Faster, Stronger", "Next did not skip the song")
        XCTAssertEqual(app.buttons["session-music-play"].label, "Pause music")
        app.buttons["session-music-play"].tap()
        XCTAssertEqual(app.buttons["session-music-play"].label, "Play music", "Pause did not pause")
        app.buttons["session-music-play"].tap()
        shot("1-runner-music")

        // The edit sheet, over the runner.
        app.buttons["session-edit"].tap()
        XCTAssertTrue(app.staticTexts["runner-edit-title"].waitForExistence(timeout: 5), "the edit sheet did not open")
        XCTAssertEqual(app.staticTexts["runner-edit-sets-value"].label, "3")
        app.buttons["runner-edit-swap-leg-press"].tap()
        let swapped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Edit Leg press"), object: app.staticTexts["runner-edit-title"])
        XCTAssertEqual(XCTWaiter().wait(for: [swapped], timeout: 3), .completed, "the swap did not land")
        app.buttons["runner-edit-sets-plus"].tap()
        XCTAssertEqual(app.staticTexts["runner-edit-sets-value"].label, "4")
        app.buttons["runner-edit-lb-plus"].tap()
        XCTAssertEqual(app.staticTexts["runner-edit-lb-value"].label, "25 lb")
        app.buttons["runner-edit-add-lunge"].tap()
        let changes = any(app, "runner-edit-changes")
        XCTAssertTrue(changes.waitForExistence(timeout: 3))
        for line in ["Swapped Goblet squat for Leg press", "Added Lunge 3x10", "Leg press: 4 sets (was 3)", "Leg press: 25 lb (was 20 lb)"] {
            XCTAssertTrue(changes.label.contains(line), "the change list misses \(line): \(changes.label)")
        }
        shot("2-edit-sheet")
        app.buttons["runner-edit-close"].tap()

        // Back in the runner, never left: the move is the new one, its sets the new count.
        let move = app.staticTexts["session-move"]
        XCTAssertTrue(move.waitForExistence(timeout: 5))
        XCTAssertEqual(move.label, "Leg press")
        XCTAssertTrue(app.staticTexts["session-where"].label.contains("of 4"), "the set count did not follow: \(app.staticTexts["session-where"].label)")
        XCTAssertTrue(app.staticTexts["session-where"].label.contains("of 3"), "the added move is not in the session: \(app.staticTexts["session-where"].label)")
        XCTAssertTrue(app.staticTexts["session-clock"].exists, "the clock stopped")
        shot("3-runner-edited")
    }
}
