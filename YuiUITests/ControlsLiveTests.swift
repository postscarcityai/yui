import XCTest

/// Agent controls over the live relay (YUI-70). Driven by
/// `supabase/tests/controls_e2e.py --sim <udid>`: a throwaway owner whose only
/// agent, Scout, runs on a throwaway host served by the plugin's own controls
/// code. Light: each round trip the spec names, with a shot before and after
/// (edit SOUL.md, forget one memory, a skill off and on, a schedule paused,
/// resumed and run now). Dark: every area once. The driver checks the host's
/// files afterwards. Each launch needs its own refresh token (YUI_RTS, two).
final class ControlsLiveTests: XCTestCase {
    func testRoundTrips() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rts = env["YUI_RTS"]?.split(separator: ",").map(String.init), rts.count >= 2,
              let user = env["YUI_USER"], let dir = env["YUI_SHOTS"] else {
            throw XCTSkip("run through supabase/tests/controls_e2e.py --sim <udid>")
        }
        let shots = URL(fileURLWithPath: dir)
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            try? png.write(to: shots.appending(path: "\(name).png"))
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = name
            a.lifetime = .keepAlways
            add(a)
        }
        func handshake(_ ask: String) {
            try? Data().write(to: shots.appending(path: "need-\(ask)"))
            let done = shots.appending(path: "\(ask)-ok")
            let end = Date.now.addingTimeInterval(30)
            while !FileManager.default.fileExists(atPath: done.path), Date.now < end { sleep(1) }
        }
        let app = XCUIApplication()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func text(_ s: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
        }
        func launch(_ n: Int, _ appearance: String) {
            app.launchArguments = ["-yuiRefreshToken", rts[n], "-yuiUserID", user, "-appearance", appearance, "-yuiDrawer"]
            app.launch()
            let allow = springboard.buttons["Allow"]
            if allow.waitForExistence(timeout: 6) { allow.tap() }
            let tab = app.buttons["drawer-tab-controls"]
            XCTAssertTrue(tab.waitForExistence(timeout: 30), "no Controls tab (\(appearance))")
            tab.tap()
            XCTAssertTrue(app.buttons["controls-soul"].waitForExistence(timeout: 20), "the host's report never arrived")
            let live = NSPredicate(format: "isEnabled == true")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: live, object: app.buttons["controls-soul"])],
                                          timeout: 60), .completed, "the host never read online")
        }
        func open(_ s: String) {
            app.buttons["controls-\(s)"].tap()
        }
        func close() {
            for _ in 0..<4 {
                let x = app.buttons["controls-close"]
                if x.exists, x.isHittable { x.tap(); sleep(1); return }
                if !app.staticTexts["controls-sheet"].exists { return }  // the sheet is gone
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))  // edge swipe: back
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
                sleep(1)
            }
        }

        func tapSwitch(_ sw: XCUIElement) { sw.switches.firstMatch.exists ? sw.switches.firstMatch.tap() : sw.tap() }

        // Light: the round trips.
        launch(0, "light")
        sleep(1)
        shot("L00-tab")

        open("soul")
        XCTAssertTrue(text("trail-running coach").waitForExistence(timeout: 10), "SOUL.md did not come from the host")
        sleep(1)
        shot("L01-soul-before")
        app.buttons["controls-edit"].tap()
        let editor = app.textViews["controls-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("\nAlways end with one question.")
        app.buttons["controls-save"].tap()
        XCTAssertTrue(text("Always end with one question").waitForExistence(timeout: 12), "the save did not come back")
        handshake("soul")
        sleep(1)
        shot("L02-soul-after")
        close()

        open("memory")
        XCTAssertTrue(text("Knee felt tight").waitForExistence(timeout: 10), "memory did not come from the host")
        sleep(1)
        shot("L03-memory-before")
        text("Knee felt tight").tap()
        let forget = app.buttons["controls-forget"]
        XCTAssertTrue(forget.waitForExistence(timeout: 10))
        forget.tap()
        XCTAssertTrue(app.alerts.buttons["Keep it"].waitForExistence(timeout: 4), "Forget did not ask first")
                app.alerts.buttons["Forget"].tap()
        XCTAssertTrue(text("What it remembers").waitForExistence(timeout: 12))
        sleep(2)
        XCTAssertFalse(text("Knee felt tight").exists, "the forgotten memory is still listed")
        shot("L04-memory-after")
        XCTAssertTrue(text("hidden on your Mac").exists, "the token-shaped memory is not hidden")
        close()

        open("skills")
        let sw = app.switches["skill-switch-trail-planner"]
        XCTAssertTrue(sw.waitForExistence(timeout: 10))
        sleep(1)
        shot("L05-skill-before")
        tapSwitch(sw)
        XCTAssertTrue(text("is off").waitForExistence(timeout: 10), "switching the skill off did not land")
        shot("L06-skill-off")
        sleep(3)
        tapSwitch(sw)
        XCTAssertTrue(text("is on").waitForExistence(timeout: 10), "switching the skill on did not land")
        shot("L07-skill-on")
        close()

        open("schedules")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "schedule-row-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        sleep(1)
        shot("L08-schedules-before")
        row.tap()
        XCTAssertTrue(app.buttons["controls-pause"].waitForExistence(timeout: 10))
        shot("L09-schedule-item")
        app.buttons["controls-pause"].tap()
        XCTAssertTrue(app.buttons["controls-resume"].waitForExistence(timeout: 12), "pause did not land")
        shot("L10-schedule-paused")
        app.buttons["controls-resume"].tap()
        XCTAssertTrue(app.buttons["controls-pause"].waitForExistence(timeout: 12), "resume did not land")
        shot("L11-schedule-resumed")
        app.buttons["controls-run"].tap()
        XCTAssertTrue(text("Runs within a minute").waitForExistence(timeout: 12), "run now did not land")
        shot("L12-schedule-run")
        close()
        app.terminate()

        // Dark: every area once.
        launch(1, "dark")
        sleep(1)
        shot("D00-tab")
        for (i, s) in ["soul", "memory", "skills", "schedules", "model", "channels"].enumerated() {
            open(s)
            let ready = ["soul": "trail-running coach", "memory": "Long runs", "skills": "trail-planner",
                         "schedules": "morning brief", "model": "Claude on this Mac", "channels": "Yui"][s]!
            XCTAssertTrue(text(ready).waitForExistence(timeout: 12), "\(s) did not load in dark")
            sleep(1)
            shot("D0\(i + 1)-\(s)")
            close()
        }
    }
}
