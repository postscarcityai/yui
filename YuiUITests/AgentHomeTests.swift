import XCTest

/// Every agent's home (YUI-168, spec yuigui/spec/HOME.md). Chris on build 244: "when I go
/// to one of these agent screens, I should see a unique set of shortcuts ... For Arnold I
/// want to see the workout I have scheduled for today by simply swiping over to that next
/// full screen ... Notifications should really just be right on this home screen." And on
/// Sep 27: no dots, the person swipes on instinct, and no competing swipe actions.
/// Demo account (-yuiDemoHome: each thread opens on the home yui-agents writes), no network.
/// Screenshots go to `YUI_SHOTS` when set.
final class AgentHomeTests: XCTestCase {
    /// Arnold: his chips, then This week, then Today's workout, a swipe each; no dots.
    func testArnoldLight() throws { try arnold("light") }
    func testArnoldDark() throws { try arnold("dark") }

    private func arnold(_ appearance: String) throws {
        let app = launch("arnold", appearance, waiting: true)
        let home = app.descendants(matching: .any)["stage-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 15), "Arnold's stage is not his home")
        let start = app.buttons["home-chip-workout"], split = app.buttons["home-chip-split"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), "no Start a workout chip")
        XCTAssertTrue(split.exists, "no My split chip")
        XCTAssertLessThan(start.frame.minX, split.frame.minX, "the most important chip comes first")
        XCTAssertGreaterThan(start.frame.height, 50, "the chips are big on the home")
        // Waiting on you, right on the home (Chris: "Notifications should really just be right on this home screen").
        XCTAssertTrue(app.buttons["home-menu-sat"].exists, "the ask is not on the home")
        XCTAssertTrue(app.buttons["home-menu-max"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'page-tab-'")).firstMatch.exists, "dots")
        XCTAssertEqual(app.pagePosition.value as? String, "1 of 4", "VoiceOver does not hear where it is")
        sleep(1)
        shot("arnold-\(appearance)-1-home")

        app.swipeLeft()
        let week = app.descendants(matching: .any)["stage-screen-2"]
        XCTAssertTrue(week.waitForExistence(timeout: 5), "a swipe left did not show This week")
        XCTAssertTrue(week.staticTexts["This week"].waitForExistence(timeout: 3), "screen 2 is not This week")
        XCTAssertFalse(start.exists, "the chips are on a screen")
        sleep(1)
        shot("arnold-\(appearance)-2-this-week")

        app.swipeLeft()
        let today = app.descendants(matching: .any)["stage-screen-3"]
        XCTAssertTrue(today.waitForExistence(timeout: 5), "a swipe left did not show Today's workout")
        XCTAssertTrue(today.staticTexts["Today's workout"].exists, "screen 3 is not Today's workout")
        sleep(1)
        shot("arnold-\(appearance)-3-today")

        app.swipeRight()
        app.swipeRight()
        XCTAssertTrue(home.waitForExistence(timeout: 5), "two swipes right did not come home")
        // My split opens the live This week page, no turn.
        split.tap()
        XCTAssertTrue(week.waitForExistence(timeout: 5), "My split did not open This week")
        XCTAssertFalse(app.descendants(matching: .any)["stage-working"].exists, "My split started a turn")
    }

    /// Basil: Log a meal fills the field to finish; Grocery list opens its page.
    func testBasilLogAMeal() throws {
        let app = launch("basil", "light")
        let log = app.buttons["home-chip-log"]
        XCTAssertTrue(log.waitForExistence(timeout: 15), "no Log a meal chip")
        // Nothing waiting: the home says nothing more (no list, no filler line).
        XCTAssertFalse(app.descendants(matching: .any)["home-waiting"].exists, "something reads as waiting on a fresh home")
        shot("basil-light-1-home")
        log.tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Log a meal did not open the field")
        XCTAssertEqual(field.value as? String, "Log a meal: ", "the field is not ready to finish")
        shot("basil-light-2-log")
        app.buttons["stage-back-to-mic"].tap()
        app.buttons["home-chip-groceries"].tap()
        let groceries = app.descendants(matching: .any)["stage-screen-4"]
        XCTAssertTrue(groceries.waitForExistence(timeout: 5), "Grocery list did not open screen 4")
        XCTAssertTrue(groceries.staticTexts["Greek yogurt"].exists)
        app.goToScreen(2)
        XCTAssertTrue(app.descendants(matching: .any)["stage-screen-2"].staticTexts["Macros vs goal"].waitForExistence(timeout: 5))
        shot("basil-light-3-today")
    }

    /// Gouda: the looper, the chords and the keys a swipe apart, ready to play; the looper plays.
    func testGoudaLooperPlays() throws {
        let app = launch("gouda", "dark")
        XCTAssertTrue(app.buttons["home-chip-jam"].waitForExistence(timeout: 15), "no Jam chip")
        shot("gouda-dark-1-home")
        app.swipeLeft()
        let play = app.descendants(matching: .any)["stage-screen-2"].buttons["loop-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 5), "no looper on screen 2")
        play.tap()
        XCTAssertEqual(play.label, "Stop", "the looper did not start")
        sleep(1)
        shot("gouda-dark-2-looper")
        play.tap()
        // The instruments own a drag that starts on them, so page from the edge.
        app.goToScreen(3)
        XCTAssertTrue(app.descendants(matching: .any)["stage-screen-3"].waitForExistence(timeout: 5), "no chords on screen 3")
        shot("gouda-dark-3-chords")
        app.goToScreen(4)
        let keys = app.descendants(matching: .any)["stage-screen-4"]
        XCTAssertTrue(keys.waitForExistence(timeout: 5), "no keys on screen 4")
        sleep(1)
        shot("gouda-dark-4-keys")
        // The keys own a drag that starts on them: it plays, it does not change screens.
        let key = keys.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'key-'")).element(boundBy: 3)
        if key.exists {
            let on = key.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            on.press(forDuration: 0.05, thenDragTo: on.withOffset(CGVector(dx: -120, dy: 0)))
            XCTAssertTrue(keys.exists, "a drag on the keys changed screens")
        }
        // The page's edge is the swipe's.
        edge(app, x: 0.03).press(forDuration: 0.05, thenDragTo: edge(app, x: 0.9))
        XCTAssertTrue(app.descendants(matching: .any)["stage-screen-3"].waitForExistence(timeout: 5),
                      "a drag right from the edge over the keys did not go back")
    }

    /// YUI-200 (Chris, TestFlight: "play a loop and switch around to the other screens without it
    /// stopping"): the loop and the click keep going while the person swipes between Gouda's screens.
    func testGoudaMusicKeepsPlayingAcrossScreens() throws {
        let app = launch("gouda", "dark")
        XCTAssertTrue(app.buttons["home-chip-jam"].waitForExistence(timeout: 15), "no Jam chip")
        app.goToScreen(2)
        let play = app.descendants(matching: .any)["stage-screen-2"].buttons["loop-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 5), "no looper on screen 2")
        play.tap()
        XCTAssertEqual(play.label, "Stop", "the looper did not start")
        // The click on Chords, over the loop.
        app.goToScreen(3)
        let click = app.descendants(matching: .any)["stage-screen-3"].buttons["metronome-play"]
        XCTAssertTrue(click.waitForExistence(timeout: 5), "no click on screen 3")
        click.tap()
        XCTAssertEqual(click.label, "Stop", "the click did not start")
        // Away to the keys and the practice page, then home and back.
        app.goToScreen(4)
        XCTAssertTrue(app.descendants(matching: .any)["stage-screen-4"].waitForExistence(timeout: 5))
        app.goToScreen(5)
        XCTAssertTrue(app.descendants(matching: .any)["stage-screen-5"].waitForExistence(timeout: 5))
        sleep(1)
        app.goToScreen(2)
        let again = app.descendants(matching: .any)["stage-screen-2"].buttons["loop-play"]
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        XCTAssertEqual(again.label, "Stop", "the loop stopped when the person left its screen")
        shot("gouda-dark-loop-still-playing")
        app.goToScreen(3)
        let clickAgain = app.descendants(matching: .any)["stage-screen-3"].buttons["metronome-play"]
        XCTAssertTrue(clickAgain.waitForExistence(timeout: 5))
        XCTAssertEqual(clickAgain.label, "Stop", "the click stopped when the person left its screen")
        // Stop works from the screen it is on now.
        clickAgain.tap()
        XCTAssertEqual(clickAgain.label, "Start")
        app.goToScreen(2)
        let stop = app.descendants(matching: .any)["stage-screen-2"].buttons["loop-play"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()
        XCTAssertEqual(stop.label, "Play")
    }

    /// YUI-200 (Chris: "If I just push that button, it should really just take me to the screen. The
    /// guitar tuner should always live at the end of the Gouda screen list."): Tune up opens the
    /// tuner, the last screen, and sends no message.
    func testGoudaTuneUpOpensTheTunerWithNoTurn() throws {
        try tuneUpOpensTheTuner("dark")
    }

    /// YUI-252: the same, in light.
    func testGoudaTuneUpOpensTheTunerWithNoTurnLight() throws {
        try tuneUpOpensTheTuner("light")
    }

    private func tuneUpOpensTheTuner(_ look: String) throws {
        let app = launch("gouda", look)
        let tune = app.buttons["home-chip-tune"]
        XCTAssertTrue(tune.waitForExistence(timeout: 15), "no Tune up chip")
        XCTAssertEqual(app.pagePosition.value as? String, "1 of 6", "the tuner is not the sixth and last screen")
        tune.tap()
        let screen = app.descendants(matching: .any)["stage-screen-6"]
        XCTAssertTrue(screen.waitForExistence(timeout: 5), "Tune up did not open screen 6")
        XCTAssertEqual(app.pagePosition.value as? String, "6 of 6", "the tuner is not last")
        XCTAssertFalse(app.descendants(matching: .any)["stage-working"].exists, "Tune up started a turn")
        XCTAssertFalse(app.staticTexts["Tune my guitar"].exists, "Tune up sent its words as a message")
        XCTAssertFalse(app.staticTexts["You: Tune my guitar"].exists, "Tune up sent its words as a message")
        // YUI-206 recheck: the tuner listens on this page and the app stays up.
        sleep(3)
        XCTAssertTrue(app.descendants(matching: .any)["stage-screen-6"].exists, "the app lost the tuner page")
        shot("gouda-\(look)-tuner-no-turn")
        app.goToScreen(1)
        XCTAssertTrue(tune.waitForExistence(timeout: 5), "could not page back home")
    }

    /// One sideways gesture: from five places on the home a drag left lands on screen 2, over
    /// the words, a chip, an ask, the edge and the bottom bar.
    func testOneSidewaysGesture() throws {
        let app = launch("arnold", "light", waiting: true)
        XCTAssertTrue(app.buttons["home-chip-workout"].waitForExistence(timeout: 15), "no home")
        let bar = app.buttons["stage-type"]
        let starts: [(String, XCUICoordinate)] = [
            ("the middle", app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.3))),
            ("a chip", app.buttons["home-chip-split"].coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))),
            ("an ask", app.buttons["home-menu-sat"].coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))),
            ("the edge", edge(app, x: 0.97)),
            ("the bottom bar", app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0))
                .withOffset(CGVector(dx: 0, dy: bar.frame.midY))),
        ]
        for (name, from) in starts {
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: -240, dy: 0)))
            waitScreen(app, 2, "a drag left from \(name) did not land on screen 2")
            app.goToScreen(1)
            waitScreen(app, 1, "could not page back home after \(name)")
        }
        // Right on the home pulls the drawer out.
        app.swipeRight()
        XCTAssertTrue(app.buttons["drawer-close"].waitForExistence(timeout: 5), "a drag right on the home did not open the drawer")
    }

    /// Yui's home is a calm chat: two chips, no page of agent cards (Chris on TestFlight, 2026-10-05:
    /// "Remove this screen", t_5b44f121). The crew is one tap away in the agent list, where it always was.
    func testYuiHomeHasNoCrewPageDark() throws { try yuiHome("dark") }
    func testYuiHomeHasNoCrewPageLight() throws { try yuiHome("light") }

    private func yuiHome(_ appearance: String, rows: URL? = nil) throws {
        let app = launch("yui", appearance, rows: rows)
        XCTAssertTrue(app.buttons["home-chip-add"].waitForExistence(timeout: 15), "no Add an agent chip")
        XCTAssertTrue(app.buttons["home-chip-new"].exists, "no What's new chip")
        XCTAssertFalse(app.buttons["screen-pill-2"].exists, "a second page is back on Yui's home")
        XCTAssertFalse(app.staticTexts["Workouts built around your week and body"].exists, "the crew cards are on screen")
        sleep(1)
        shot("yui-\(appearance)-1-home")
        app.swipeLeft()
        XCTAssertFalse(app.descendants(matching: .any)["stage-screen-2"].waitForExistence(timeout: 2), "a swipe found a crew page")
        // The agents are where Chris wants them: the agent list in the drawer, every one of them.
        app.buttons["stage-menu"].tap()
        let bar = app.buttons["drawer-agent-bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "no agent bar in the drawer")
        bar.tap()
        for name in ["Arnold", "Basil", "Gouda", "Penny", "Quill"] {
            let row = app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + ",")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(name) is not in the agent list")
        }
        sleep(1)
        shot("yui-\(appearance)-2-agents")
        // A -yuiThreadRows file is every thread's rows, so Gouda's own home only opens on the demo rows.
        guard rows == nil else { return }
        app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "Gouda", "Gouda,")).firstMatch.tap()
        XCTAssertTrue(app.buttons["home-chip-jam"].waitForExistence(timeout: 8), "Gouda did not open from the list")
    }

    /// Someone whose Yui wrote the old home (the crew on page 2, saved as "your crew") opens the new
    /// build: the page is gone, the chips stay, nothing else moves.
    func testAnOldCrewPageIsDroppedOnLaunch() throws {
        let old = "```yui\nmenu shortcut@new \"What's new\" say=\"What's new in Yui?\"\nmenu shortcut@add \"Add an agent\" say=\"Make me a new agent: \"\n>2\n"
            + [("arnold", "Arnold", "Workouts built around your week and body", "Trainer"),
               ("basil", "Basil", "Eat better without counting everything", "Nutritionist"),
               ("gouda", "Gouda", "Beats, chords and practice, right on screen", "Musician"),
               ("penny", "Penny", "Get your week out of your head", "Planner")]
                .map { "card@crew-\($0.0) \($0.1) \"\($0.2)\" sub=\($0.3) url=yui://agent/demo-\($0.0)/thread cta=Open" }
                .joined(separator: "\n") + "\nsave your crew\n```"
        let f = FileManager.default.temporaryDirectory.appending(path: "old-home-\(UUID().uuidString).json")
        let rows: [[String: Any]] = [["id": "home-yui", "sender": "agent", "kind": "text", "body": old,
                                      "meta": ["native": "home"], "created_at": "2026-09-28T10:00:00+00:00"]]
        try JSONSerialization.data(withJSONObject: rows).write(to: f)
        try yuiHome("dark", rows: f)
    }

    // MARK: helpers

    private func launch(_ agent: String, _ appearance: String, waiting: Bool = false, rows: URL? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoHome", "-yuiAgent", agent,
                               "-appearance", appearance] + (waiting ? ["-yuiDemoWaiting"] : [])
            + (rows.map { ["-yuiThreadRows", $0.path] } ?? [])
        app.launch()
        return app
    }

    private func edge(_ app: XCUIApplication, x: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.45))
    }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "home-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
