import XCTest

/// Arnold coaches a timed workout, start to finish (YUI-220). The plan opens as a full-screen
/// session, no overview first: a work set, then the app asks reps and weight, then the rest
/// countdown, then the next set. `-yuiRunnerFast` makes sets 6 s and rests 5 s.
/// A heavy lifter's last set waits for Stop and logs its reps; a new lifter never sees it.
/// Demo account, no network. `YUI_SHOTS=<dir>` saves screenshots.
final class WorkoutSessionFlowTests: XCTestCase {
    /// As runtime/src/workouts.ts runnerLines sends it. No apostrophes (launch args are plists).
    private static func runner(heavy: Bool) -> String {
        [
            "say Upper. 2 moves, one set at a time. Lets go.",
            "plan@wk-20260930-wed Upper submit=\"Finish workout\"",
            "page Upper body=\"2 moves, about 20 minutes. Rest about 60 seconds between sets.\" points=\"Bench press 2x8\"|\"Plank 2x30s\"",
            "pick@e1-sets \"Bench press: sets done\" \"Set 1\"|\"Set 2\"|Skip tag=\"1 of 2\" title=\"Bench press\" body=\"Target 2 x 8 at 135 lb.\" cue=\"Brace. Slow down.\" work=32\(heavy ? " +fail" : "")",
            "slide@e1-reps \"Bench press: reps per set\" 1-30 value=8",
            "slide@e1-lb \"Bench press: weight in lb\" 0-300 value=135 step=5 unit=lb",
            "pick@e2-sets \"Plank: sets done\" \"Set 1\"|\"Set 2\"|Skip tag=\"2 of 2\" title=Plank body=\"Target 2 x 30s.\" cue=\"Straight line. Squeeze everything.\" work=30",
            "slide@e2-secs \"Plank: seconds per set\" 5-180 value=30 step=5",
            "choose@feel \"How did it feel?\" Easy|\"Just right\"|Hard",
            "end",
        ].joined(separator: "\\n")
    }

    private var appearance = "dark"
    private var heavy = true

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "session-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "session-\(appearance)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func launch(_ log: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoHome", "-yuiAgent", "arnold", "-appearance", appearance,
                               "-yuiThemeDemo", Self.runner(heavy: heavy), "-yuiDemoPrompt", "Start my workout", "-yuiDemoDelay", "0.5",
                               "-yuiEventLog", log, "-yuiRunnerReset", "-yuiRunnerFast"]
        app.launch()
        return app
    }

    private func b(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let all = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", id, id))
        return all.allElementsBoundByIndex.first { $0.isHittable } ?? all.firstMatch
    }

    private func t(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let all = app.staticTexts.matching(identifier: id)
        return all.allElementsBoundByIndex.first { $0.isHittable } ?? all.firstMatch
    }

    /// Waits until the phase label says `phase`.
    private func phase(_ app: XCUIApplication, _ phase: String, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let el = app.staticTexts["session-phase"].firstMatch
            if el.exists, el.label.caseInsensitiveCompare(phase) == .orderedSame { return true }
            usleep(200_000)
        }
        return false
    }

    func testHeavyLifterDark() throws { try run("dark", heavy: true) }
    func testHeavyLifterLight() throws { try run("light", heavy: true) }
    func testNewLifterNeverSeesFailureDark() throws { try run("dark", heavy: false) }

    private func run(_ look: String, heavy: Bool) throws {
        appearance = look
        self.heavy = heavy
        let log = FileManager.default.temporaryDirectory.appending(path: "yui-session-events-\(look)-\(heavy).jsonl").path
        try? FileManager.default.removeItem(atPath: log)
        let app = launch(log)

        XCTAssertTrue(app.staticTexts["Upper"].waitForExistence(timeout: 15), "the runner never opened")
        XCTAssertFalse(b(app, "runner-start").exists, "an overview with a second Start came first")

        // Work set: its move, Arnold's line, the clock. Then the taps stop.
        XCTAssertTrue(phase(app, "Work", timeout: 5), "Start did not open a work set")
        XCTAssertEqual(t(app, "session-move").label, "Bench press")
        XCTAssertEqual(t(app, "session-cue").label, "Brace. Slow down.")
        shot("1-work")

        // Set 1 ends on its own and the app asks what was done: nudge the reps and weight, then log it.
        XCTAssertTrue(phase(app, "Log", timeout: 12), "the set did not ask what was done")
        XCTAssertEqual(t(app, "session-log-title").label, "Set 1 of 2 done")
        XCTAssertEqual(t(app, "session-log-reps-value").label, "8")
        XCTAssertEqual(t(app, "session-log-lb-value").label, "135 lb")
        XCTAssertTrue(b(app, "session-log-reps-chip-8").exists, "no chips around the target")
        b(app, "session-log-reps-plus").tap()
        b(app, "session-log-lb-plus").tap()
        XCTAssertEqual(t(app, "session-log-reps-value").label, "9")
        XCTAssertEqual(t(app, "session-log-lb-value").label, "140 lb")
        shot("1b-log")
        b(app, "session-log-done").tap()

        // Then the rest counts down, saying what is next.
        XCTAssertTrue(phase(app, "Rest", timeout: 5), "the rest did not start after the log")
        XCTAssertTrue(t(app, "session-next").label.hasPrefix("Next: Bench press"), "rest line: \(t(app, "session-next").label)")
        shot("2-rest")

        if heavy {
            // The last set of the lift goes to failure: no clock, a big Stop.
            XCTAssertTrue(phase(app, "To failure", timeout: 14), "the last set did not go to failure")
            XCTAssertEqual(t(app, "session-fail-note").label, "To failure. Stop when form breaks.")
            shot("3-failure")
            b(app, "session-fail-plus").tap()
            b(app, "session-fail-plus").tap()
            XCTAssertEqual(t(app, "session-fail-value").label, "10")
            b(app, "session-stop").tap()
            XCTAssertTrue(phase(app, "Log", timeout: 5), "the failure set did not ask for its weight")
            XCTAssertEqual(t(app, "session-log-reps-value").label, "10", "the log did not start from the reps at Stop")
            b(app, "session-log-done").tap()
        } else {
            // Set 2 asks again, starting where set 1 ended.
            XCTAssertTrue(phase(app, "Log", timeout: 14), "set 2 did not ask")
            XCTAssertFalse(b(app, "session-stop").exists, "a new lifter got a Stop button")
            XCTAssertEqual(t(app, "session-log-reps-value").label, "9", "set 2 did not start from set 1")
            b(app, "session-log-done").tap()
        }

        // The plank asks for its seconds, and the finish follows.
        let asked = phase(app, "Log", timeout: 40)
        shot("3b-plank")
        XCTAssertTrue(asked, "the plank did not ask")
        XCTAssertFalse(t(app, "session-log-lb-value").exists, "a plank asked for a weight")
        b(app, "session-log-done").tap()
        XCTAssertTrue(phase(app, "Rest", timeout: 5), "no rest between the plank's sets")
        let second = phase(app, "Log", timeout: 25)
        shot("3c-plank-2")
        XCTAssertTrue(second, "the plank's second set did not ask")
        b(app, "session-log-done").tap()
        XCTAssertTrue(app.staticTexts["session-finish"].waitForExistence(timeout: 60), "the session did not finish after the last log")
        XCTAssertEqual(t(app, "session-sets").label, "4 of 4")
        shot("4-finish")
        b(app, "Just right").tap()
        b(app, "session-log").tap()
        XCTAssertTrue(app.staticTexts["session-logged"].waitForExistence(timeout: 5), "the log was not written")

        let events = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        let plan = events.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }.compactMap { $0["plan"] as? [String: Any] }.last
        let p = try XCTUnwrap(plan, "no {plan} event: \(events)")
        XCTAssertEqual(p["e1-sets"] as? [String], ["Set 1", "Set 2"])
        XCTAssertEqual(p["e2-sets"] as? [String], ["Set 1", "Set 2"])
        XCTAssertEqual(p["feel"] as? String, "Just right")
        XCTAssertEqual(p["e1-lb"] as? Double, 140, "Send carries what the sets were done at")
        if heavy { XCTAssertEqual(p["e1-fail"] as? Double, 10) } else { XCTAssertNil(p["e1-fail"]) }
    }
}
