import XCTest

/// A stranger's first plan on the live backend (YUI-228): a fresh non-demo account picks Arnold, answers his
/// intake, taps Send, and the built week is on screen with no further questions. Driven by
/// supabase/tests/first_plan_live_sim_e2e.py, which makes the throwaway account and times the answer.
/// Skips without TEST_RUNNER_YUI_RT, TEST_RUNNER_YUI_USER and TEST_RUNNER_YUI_SHOTS.
final class LiveFirstPlanTests: XCTestCase {
    var shots = URL(fileURLWithPath: "/tmp")
    var tag = "dark"
    func mark(_ name: String) {
        let line = "{\"step\":\"\(name)\",\"t\":\(Date().timeIntervalSince1970)}\n"
        let f = shots.appending(path: "marks.jsonl")
        if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: f) }
    }
    func shot(_ name: String) {
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: "\(tag)-\(name).png"))
    }

    func testStrangerFirstPlan() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rt = env["YUI_RT"], let user = env["YUI_USER"], let dir = env["YUI_SHOTS"] else { throw XCTSkip("driver only") }
        shots = URL(fileURLWithPath: dir)
        tag = env["YUI_APPEARANCE"] ?? "dark"
        continueAfterFailure = false
        let app = XCUIApplication()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
        func text(_ s: String) -> XCUIElement { app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch }
        func b(_ label: String) -> XCUIElement {
            let all = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", label, label))
            return all.allElementsBoundByIndex.first { $0.isHittable } ?? all.firstMatch
        }

        // 1. Signed in on a real session: the crew picker, Arnold only.
        app.launchArguments = ["-yuiRefreshToken", rt, "-yuiUserID", user, "-appearance", tag]
        app.launch()
        XCTAssertTrue(any("crew-pick-title").waitForExistence(timeout: 60), "no crew picker")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        any("crew-pick-arnold").tap()
        any("crew-start").tap()
        XCTAssertTrue(text("Your crew is here").waitForExistence(timeout: 60), "Yui's hello never came")

        // 2. Open Arnold: his hello and the intake.
        if !text("Your first plan").waitForExistence(timeout: 6) && !text("What are we training for?").exists {
            if !any("drawer-agent-bar").exists {
                let m = app.buttons["Agent menu"].firstMatch
                if m.exists { m.tap() } else { app.swipeRight() }
                sleep(1)
            }
            if any("drawer-agent-bar").waitForExistence(timeout: 8) {
                any("drawer-agent-bar").tap(); sleep(1)
                let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Arnold'")).firstMatch
                if row.waitForExistence(timeout: 8) { row.tap() }
            }
        }
        let opener = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Your first plan' OR label CONTAINS 'Build your split'")).firstMatch
        if opener.waitForExistence(timeout: 10) { opener.tap() }
        XCTAssertTrue(text("What are we training for?").waitForExistence(timeout: 15) || text("Step 1 of").waitForExistence(timeout: 5), "the intake never showed")
        sleep(1); shot("01-intake")
        mark("intake-shown")

        // 3. Answer, one tap each, then Send. Whether the intake is one screen or a stepper, the same answers.
        let answers = ["Lift heavy", "3", "45 min", "Dumbbells", "Some experience"]
        var sent = false
        for _ in 0..<14 where !sent {
            for a in answers where app.buttons.matching(NSPredicate(format: "label == %@", a)).count > 0 {
                var o = b(a)
                if !o.isHittable { app.swipeUp(); usleep(400_000); o = b(a) }
                if o.isHittable { o.tap(); usleep(900_000) }
            }
            let send = app.buttons["stage-send"]
            if send.exists && send.isEnabled {
                if !send.isHittable { app.swipeUp() }
                shot("02-answered")
                mark("send-tapped"); send.tap(); sent = true; break
            }
            for n in ["Next", "Review", "Build my week"] where app.buttons.matching(NSPredicate(format: "label == %@", n)).count > 0 {
                let e = b(n)
                if e.isHittable {
                    if n == "Build my week" { shot("02-answered"); mark("send-tapped"); sent = true }
                    e.tap(); break
                }
            }
            usleep(600_000)
        }
        XCTAssertTrue(sent, "never reached Send")

        // 4. Arnold's week is on screen, with no more questions.
        let built = text("Your week is built")
        XCTAssertTrue(built.waitForExistence(timeout: 60), "the week was not built in 60 s")
        mark("week-built")
        XCTAssertFalse(text("Two things left").exists, "a second wizard opened")
        XCTAssertFalse(text("Finish your split").exists, "a second wizard opened")
        sleep(2); shot("03-built")
        let close = app.buttons["Close full screen"]
        if close.exists { close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); sleep(1) }
        app.goToScreen(2)
        XCTAssertTrue(text("Workouts this week").waitForExistence(timeout: 8), "no This week")
        XCTAssertTrue(text("0 of 3").waitForExistence(timeout: 8), "This week is not the three built days")
        sleep(1); shot("04-this-week")
        app.goToScreen(3)
        XCTAssertTrue(text("Today's workout").waitForExistence(timeout: 8), "no Today")
        sleep(1); shot("05-today")
        mark("done")
    }
}
