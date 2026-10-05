import XCTest

/// Arnold runs your workout (YUI-182). The whole runner: a set ticked starts the
/// rest on its own, reps and weight nudge, "done" out loud ticks the next set. Then
/// the app is killed and relaunched, and it comes back on the same move with the
/// same sets; then five trips to another agent and back, and Finish sends one
/// `{plan}` the runtime reads. Chris (Sep 28): the 0.5.0 switch-agent crash hid
/// behind the demo account's memory, so the runner keeps its place in UserDefaults
/// and this test only passes if it comes back from there. Demo account, no network.
/// `YUI_SHOTS=<dir>` saves screenshots.
final class WorkoutRunnerFlowTests: XCTestCase {
    /// As runtime/src/workouts.ts runnerLines sends it. No apostrophes (launch args are plists).
    static let runner = [
        "say Upper. 2 moves, one set at a time. Lets go.",
        "plan@wk-20260928-mon Upper submit=\"Finish workout\"",
        "page Upper body=\"2 moves, about 45 minutes. Rest about 75 seconds between sets.\" points=\"Bench press 3x8\"|\"Plank 3x30s\"",
        "pick@e1-sets \"Bench press: sets done\" \"Set 1\"|\"Set 2\"|\"Set 3\"|Skip tag=\"1 of 2\" title=\"Bench press\" body=\"Feet flat, bar to mid chest. Target 3 x 8 at 135 lb. Tick each set as you finish it, or Skip.\"",
        "slide@e1-reps \"Bench press: reps per set\" 1-30 value=8",
        "slide@e1-lb \"Bench press: weight in lb\" 0-300 value=135 step=5 unit=lb",
        "pick@e2-sets \"Plank: sets done\" \"Set 1\"|\"Set 2\"|\"Set 3\"|Skip tag=\"2 of 2\" title=Plank body=\"Straight line, squeeze everything. Target 3 x 30s.\"",
        "slide@e2-secs \"Plank: seconds per set\" 5-180 value=30 step=5",
        "choose@feel \"How did it feel?\" Easy|\"Just right\"|Hard",
        "end",
    ].joined(separator: "\\n")

    private var appearance = "light"

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "runner-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "runner-\(appearance)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func launch(_ log: String, fresh: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoHome", "-yuiAgent", "arnold", "-appearance", appearance,
                               "-yuiThemeDemo", Self.runner, "-yuiDemoPrompt", "Start my workout", "-yuiDemoDelay", "0.5",
                               "-yuiPTTFake", "done", "-yuiEventLog", log]
            + ["-yuiRunnerPages"] + (fresh ? ["-yuiRunnerReset"] : [])
        app.launch()
        return app
    }

    /// The one on screen: the chat keeps its own copy of the plan under the full screen.
    private func b(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let all = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", id, id))
        return all.allElementsBoundByIndex.first { $0.isHittable } ?? all.firstMatch
    }

    private func t(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let all = app.staticTexts.matching(identifier: id)
        return all.allElementsBoundByIndex.first { $0.isHittable } ?? all.firstMatch
    }

    /// The runner full screen, on its first move (Next from the overview page).
    private func toMove(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        // Every step stays mounted, so the move's rows exist before it is the page: wait for hittable.
        for _ in 0..<8 where !b(app, "runner-e1-set-1").isHittable {
            let next = b(app, "Next")
            if next.exists, next.isHittable { next.tap() }
            sleep(1)
        }
        XCTAssertTrue(b(app, "runner-e1-set-1").isHittable, "the runner never showed its first move", file: file, line: line)
    }

    /// Waits until the move's first set is on screen.
    private func onScreen(_ app: XCUIApplication, _ id: String, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if b(app, id).exists, b(app, id).isHittable { return true }
            sleep(1)
        }
        return false
    }

    func testLight() throws { try run("light") }
    func testDark() throws { try run("dark") }

    private func run(_ look: String) throws {
        appearance = look
        let log = FileManager.default.temporaryDirectory.appending(path: "yui-runner-events-\(look).jsonl").path
        try? FileManager.default.removeItem(atPath: log)
        var app = launch(log, fresh: true)

        // The overview page, then the first move.
        XCTAssertTrue(app.staticTexts["Upper"].waitForExistence(timeout: 15), "the runner never opened")
        shot("1-overview")
        toMove(app)
        XCTAssertTrue(app.staticTexts["Bench press"].exists)

        // A set ticked: the rest starts by itself.
        b(app, "runner-e1-set-1").tap()
        XCTAssertTrue(b(app, "runner-e1-set-1").isSelected, "Set 1 did not tick")
        let rest = app.descendants(matching: .any)["runner-e1-rest"]
        XCTAssertTrue(rest.waitForExistence(timeout: 3), "the rest timer did not start after the set")
        // Reps and weight nudge.
        b(app, "runner-e1-reps-plus").tap()
        b(app, "runner-e1-lb-plus").tap()
        b(app, "runner-e1-lb-plus").tap()
        XCTAssertEqual(t(app, "runner-e1-reps-value").label, "9")
        XCTAssertEqual(t(app, "runner-e1-lb-value").label, "145 lb")
        shot("2-resting")
        b(app, "runner-e1-rest-skip").tap()
        XCTAssertFalse(rest.waitForExistence(timeout: 1), "Skip rest left the timer up")

        // "done" out loud ticks the next set, and rests again.
        b(app, "runner-e1-voice").tap()
        let set2 = b(app, "runner-e1-set-2")
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: set2)],
                                     timeout: 5) == .completed, "saying done did not tick Set 2")
        XCTAssertTrue(rest.waitForExistence(timeout: 3), "no rest after the spoken set")
        shot("3-voice-done")

        // Killed mid-workout: back on the same move, same sets, same weight.
        app.terminate()
        app = launch(log, fresh: false)
        XCTAssertTrue(onScreen(app, "runner-e1-set-1", timeout: 20), "the relaunch did not come back to the move")
        let set1 = b(app, "runner-e1-set-1")
        XCTAssertTrue(set1.isSelected, "Set 1 lost on relaunch")
        XCTAssertTrue(b(app, "runner-e1-set-2").isSelected, "Set 2 lost on relaunch")
        XCTAssertFalse(b(app, "runner-e1-set-3").isSelected)
        XCTAssertEqual(t(app, "runner-e1-lb-value").label, "145 lb", "the weight lost on relaunch")
        shot("4-relaunched")

        // Five trips to another agent and back (the 0.5.0 crash path): the app stays up.
        for i in 1...5 {
            if app.buttons["Close full screen"].exists { app.buttons["Close full screen"].tap() }
            XCTAssertTrue(app.pickAgent("Yui"), "could not switch to Yui (trip \(i))")
            XCTAssertTrue(app.pickAgent("Arnold"), "could not switch back to Arnold (trip \(i))")
            XCTAssertEqual(app.state, .runningForeground, "the app died on trip \(i)")
        }
        // The demo account keeps no thread across a switch (a real one reloads it from
        // the server), so the reply comes back the way a reload brings it: a relaunch.
        // The place it opens on is only in UserDefaults.
        shot("5-back-in-thread")
        app.terminate()
        app = launch(log, fresh: false)
        XCTAssertTrue(onScreen(app, "runner-e1-set-1", timeout: 20), "the runner was gone after 5 switches")
        XCTAssertTrue(b(app, "runner-e1-set-2").isSelected, "Set 2 lost after the switches")
        shot("6-after-switches")

        // Finish: the third set, the plank, how it felt, one Send.
        b(app, "runner-e1-set-3").tap()
        b(app, "Next").tap()
        XCTAssertTrue(onScreen(app, "runner-e2-set-1", timeout: 4), "Next did not go to the plank")
        b(app, "runner-e2-set-1").tap()
        b(app, "runner-e2-secs-plus").tap()
        b(app, "Next").tap()
        XCTAssertTrue(onScreen(app, "Just right", timeout: 4), "no feel question")
        b(app, "Just right").tap()
        XCTAssertTrue(onScreen(app, "Finish workout", timeout: 4), "no review with Finish")
        let finish = b(app, "Finish workout")
        shot("7-review")
        finish.tap()
        sleep(1)
        shot("8-sent")

        let events = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        let plan = events.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }.compactMap { $0["plan"] as? [String: Any] }.last
        let p = try XCTUnwrap(plan, "no {plan} event: \(events)")
        XCTAssertEqual(p["e1-sets"] as? [String], ["Set 1", "Set 2", "Set 3"])
        XCTAssertEqual(p["e1-reps"] as? Double, 9)
        XCTAssertEqual(p["e1-lb"] as? Double, 145)
        XCTAssertEqual(p["e2-sets"] as? [String], ["Set 1"])
        XCTAssertEqual(p["e2-secs"] as? Double, 35)
        XCTAssertEqual(p["feel"] as? String, "Just right")
    }
}
