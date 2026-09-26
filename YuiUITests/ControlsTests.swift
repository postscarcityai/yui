import XCTest

/// Agent controls in the drawer (YUI-70, spec yuigui spec/CONTROLS.md). Demo account
/// with its stand-in host, no network: every area in light and dark, and each
/// round trip the spec names (edit the personality, forget a memory, a skill off
/// and on, a schedule paused, resumed and run now). Also: an offline host greys
/// the tab, a host with no report shows the About card and one line, and a shared
/// agent's drawer has no Controls. Shots go to `YUI_SHOTS`.
final class ControlsTests: XCTestCase {
    func testLight() throws { try run("light") }
    func testDark() throws { try run("dark") }

    private var tag = ""
    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(tag)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "\(tag)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func launch(_ app: XCUIApplication, _ appearance: String, agent: String, extra: [String] = []) {
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiDemoControls", "-yuiAgent", agent,
                               "-yuiDrawer", "-appearance", appearance] + extra
        app.launch()
    }

    private func run(_ appearance: String) throws {
        tag = "controls-\(appearance)"
        let app = XCUIApplication()
        func closeSheet() {
            for _ in 0..<4 {
                let x = app.buttons["controls-close"]
                if x.exists, x.isHittable { x.tap(); sleep(1); return }
                if !app.staticTexts["controls-sheet"].exists { return }  // the sheet is gone
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))  // edge swipe: back
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
                sleep(1)
            }
        }

        func text(_ s: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
        }
        launch(app, appearance, agent: "coach")
        let tab = app.buttons["drawer-tab-controls"]
        XCTAssertTrue(tab.waitForExistence(timeout: 15), "no Controls tab for an owned agent")
        tab.tap()
        let soul = app.buttons["controls-soul"]
        XCTAssertTrue(soul.waitForExistence(timeout: 5))
        for s in ["memory", "skills", "schedules", "model", "channels"] {
            XCTAssertTrue(app.buttons["controls-\(s)"].exists, "no \(s) row")
        }
        sleep(1)
        shot("00-tab")

        // Personality: rendered with its outline, then an edit round trip.
        soul.tap()
        let rendered = app.descendants(matching: .any)["controls-rendered"]
        XCTAssertTrue(rendered.waitForExistence(timeout: 8), "SOUL.md did not load")
        XCTAssertTrue(text("trail-running coach").exists, "SOUL.md is not rendered")
        XCTAssertFalse(text("## Voice").exists, "raw markdown marks show")
        sleep(1)
        shot("01-soul")
        app.buttons["controls-edit"].tap()
        let editor = app.textViews["controls-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("\nAlways end with one question.")
        shot("02-soul-editing")
        app.buttons["controls-save"].tap()
        XCTAssertTrue(text("Always end with one question").waitForExistence(timeout: 8), "the saved SOUL.md is not shown")
        shot("03-soul-saved")
        closeSheet()

        // Memory: two lists, a hidden key reads locked, forget one after a confirm.
        app.buttons["controls-memory"].tap()
        XCTAssertTrue(text("What it remembers").waitForExistence(timeout: 8))
        XCTAssertTrue(text("About you").exists)
        XCTAssertTrue(text("Knee felt tight").exists)
        sleep(1)
        shot("04-memory")
        text("Knee felt tight").tap()
        let forget = app.buttons["controls-forget"]
        XCTAssertTrue(forget.waitForExistence(timeout: 8))
        shot("05-memory-item")
        forget.tap()
                XCTAssertTrue(app.alerts.buttons["Keep it"].waitForExistence(timeout: 4), "Forget did not ask first")
        shot("06-memory-forget-confirm")
        app.alerts.buttons["Forget"].tap()
        XCTAssertTrue(text("What it remembers").waitForExistence(timeout: 8))
        sleep(1)
        XCTAssertFalse(text("Knee felt tight").exists, "the forgotten memory is still listed")
        shot("07-memory-after-forget")
        text("Strava sync token").tap()
        XCTAssertTrue(app.descendants(matching: .any)["controls-hidden-note"].waitForExistence(timeout: 8),
                      "a memory with a hidden key does not say so")
        XCTAssertFalse(app.buttons["controls-edit"].isEnabled, "a memory with a hidden key can be edited")
        shot("08-memory-hidden")
        closeSheet()

        // Skills: a switch off and on again.
        app.buttons["controls-skills"].tap()
        let sw = app.switches["skill-switch-trail-planner"]
        XCTAssertTrue(sw.waitForExistence(timeout: 8))
        sleep(1)
        shot("09-skills")
        sw.switches.firstMatch.exists ? sw.switches.firstMatch.tap() : sw.tap()
        XCTAssertTrue(text("trail-planner is off").waitForExistence(timeout: 6), "switching a skill off did not land")
        XCTAssertEqual(sw.value as? String, "0")
        shot("10-skill-off")
        sleep(3)
        sw.switches.firstMatch.exists ? sw.switches.firstMatch.tap() : sw.tap()
        XCTAssertTrue(text("trail-planner is on").waitForExistence(timeout: 6), "switching a skill on did not land")
        shot("11-skill-on")
        text("apple-reminders").firstMatch.tap()
        XCTAssertTrue(text("can be switched off, not deleted").waitForExistence(timeout: 8), "a bundled skill offers delete")
        XCTAssertFalse(app.buttons["controls-delete"].exists)
        shot("12-skill-bundled")
        closeSheet()

        // Schedules: pause, resume, run now.
        app.buttons["controls-schedules"].tap()
        let row = app.buttons["schedule-row-j-morning"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        sleep(1)
        shot("13-schedules")
        row.tap()
        let pause = app.buttons["controls-pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 8))
        shot("14-schedule-item")
        pause.tap()
        XCTAssertTrue(app.buttons["controls-resume"].waitForExistence(timeout: 8), "pause did not land")
        XCTAssertTrue(text("Paused").exists)
        shot("15-schedule-paused")
        app.buttons["controls-resume"].tap()
        XCTAssertTrue(app.buttons["controls-pause"].waitForExistence(timeout: 8), "resume did not land")
        shot("16-schedule-resumed")
        app.buttons["controls-run"].tap()
        XCTAssertTrue(text("Runs within a minute").waitForExistence(timeout: 6), "run now did not land")
        shot("17-schedule-run")
        closeSheet()

        // Model and channels, read only.
        app.buttons["controls-model"].tap()
        XCTAssertTrue(text("Claude on this Mac").waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["controls-edit"].exists)
        sleep(1)
        shot("18-model")
        closeSheet()
        app.buttons["controls-channels"].tap()
        XCTAssertTrue(text("Telegram").waitForExistence(timeout: 8))
        sleep(1)
        shot("19-channels")
        closeSheet()
        app.terminate()

        // Offline: the rows grey out.
        launch(app, appearance, agent: "counsel")
        XCTAssertTrue(tab.waitForExistence(timeout: 15))
        tab.tap()
        XCTAssertTrue(app.descendants(matching: .any)["controls-offline"].waitForExistence(timeout: 5), "no offline line")
        XCTAssertFalse(app.buttons["controls-soul"].isEnabled, "an offline host's rows can be tapped")
        sleep(1)
        shot("20-offline")
        app.terminate()

        // A host that shares nothing: the About card and one line.
        launch(app, appearance, agent: "nova")
        XCTAssertTrue(tab.waitForExistence(timeout: 15))
        tab.tap()
        XCTAssertTrue(app.descendants(matching: .any)["controls-not-shared"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["controls-about-card"].exists)
        XCTAssertFalse(app.buttons["controls-soul"].exists)
        sleep(1)
        shot("21-not-shared")
        app.terminate()

        // A shared agent: no Controls tab at all.
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoShared", "-yuiDemoControls", "-yuiAgent", "penny",
                               "-yuiDrawer", "-appearance", appearance]
        app.launch()
        XCTAssertTrue(app.buttons["drawer-tab-home"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["drawer-tab-controls"].exists, "a shared agent's drawer has Controls")
        sleep(1)
        shot("22-shared-no-controls")
    }
}
