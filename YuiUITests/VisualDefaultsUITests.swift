import XCTest

/// Every agent's own quiet visual (YUI-180): each crew agent's stage draws its pick from
/// the first open, in light and dark, at 30 fps and 15 while nothing is heard; the
/// person's switch in the agent's settings takes it away; the agent's own `visual` line and
/// `visual off` still win. Demo account, no network. Shots and numbers go to `YUI_SHOTS`.
final class VisualDefaultsUITests: XCTestCase {
    static let crew: [(handle: String, label: String)] = [
        ("yui", "Orb, listening to your voice"), ("arnold", "Waves, moving with the music"),
        ("basil", "Bloom, listening to your voice"), ("gouda", "Grain, moving with the music"),
        ("penny", "Aurora, moving on its own"), ("quill", "Orb, listening to your voice"),
    ]

    func testEveryCrewAgentHasItsOwnInLightAndDark() throws {
        var numbers: [String] = []
        for (handle, label) in Self.crew {
            for appearance in ["light", "dark"] {
                let app = launch(agent: handle, appearance: appearance)
                let visual = app.descendants(matching: .any)["stage-visual"]
                XCTAssertTrue(visual.waitForExistence(timeout: 20), "\(handle): no default visual")
                XCTAssertEqual(visual.label, label, handle)
                XCTAssertEqual(visual.value as? String, "30 fps", "\(handle): a default runs at 30")
                sleep(4)
                shot("default-\(handle)-\(appearance)")
                numbers.append("\(handle) \(appearance) | \(frames(app))")
                app.terminate()
            }
        }
        write("frames-defaults.txt", numbers.joined(separator: "\n") + "\n")
    }

    /// Nothing heard: the default idles at 15 fps, and the app keeps its own frame rate.
    func testIdlesAtFifteen() throws {
        let app = launch(agent: "arnold", appearance: "dark")
        XCTAssertTrue(app.descendants(matching: .any)["stage-visual"].waitForExistence(timeout: 20))
        sleep(6)
        let words = frames(app)
        let visual = Int(words.split(separator: " ")[1]) ?? -1
        XCTAssertGreaterThan(visual, 0, words)
        XCTAssertLessThanOrEqual(visual, 17, "idle draws at 15, got: \(words)")
        write("frames-idle.txt", "arnold idle: \(words)\n")
    }

    /// The person's switch (Settings > the agent > Visualizer) beats the default, and stays off.
    func testThePersonsSwitchTakesItAway() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgents", "-appearance", "light"]
        app.launch()
        let edit = app.buttons["Edit Coach"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 15))
        edit.tap()
        let toggle = app.switches["agent-visualizer"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "1", "the visualizer starts on")
        shot("settings-visualizer-on")
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertTrue(app.staticTexts["Nothing moves behind Coach, whatever it sends."].waitForExistence(timeout: 5))
        shot("settings-visualizer-off")
        app.buttons["Save"].tap()
        app.terminate()

        // Reopened with the switch off (the app kept it): nothing draws on the stage.
        let again = XCUIApplication()
        again.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "coach",
                                 "-appearance", "light", "-yuiVisualMeter"]
        again.launch()
        XCTAssertTrue(again.buttons["stage-type"].waitForExistence(timeout: 20))
        sleep(3)
        XCTAssertFalse(again.descendants(matching: .any)["stage-visual"].exists, "the switch is off and it still draws")
        shot("stage-switched-off")
        again.terminate()

        // On again (the switch lives on the phone: leave it as found).
        let back = XCUIApplication()
        back.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgents", "-appearance", "light"]
        back.launch()
        XCTAssertTrue(back.buttons["Edit Coach"].firstMatch.waitForExistence(timeout: 15))
        back.buttons["Edit Coach"].firstMatch.tap()
        let on = back.switches["agent-visualizer"].firstMatch
        XCTAssertTrue(on.waitForExistence(timeout: 10))
        XCTAssertEqual(on.value as? String, "0", "the switch was kept")
        on.switches.firstMatch.tap()
        back.buttons["Save"].tap()
    }

    func testTheSwitchLaunchArgumentTurnsOneAgentOff() throws {
        let app = launch(agent: "penny", appearance: "dark", extra: ["-yuiVisualOff-demo-penny", "YES"])
        XCTAssertTrue(app.buttons["stage-type"].waitForExistence(timeout: 20))
        sleep(3)
        XCTAssertFalse(app.descendants(matching: .any)["stage-visual"].exists)
        shot("penny-switched-off")
    }

    /// The agent's own line beats its default; `visual off` takes it away and sticks.
    func testTheAgentsOwnLineWinsAndOffSticks() throws {
        let app = launch(agent: "gouda", appearance: "dark", reply: "visual aurora tone=mint\\nsay \\\"Winding down.\\\"", extra: ["-yuiDemoPickupAfter", "0.6", "-yuiDemoReplyAfter", "4"])
        let visual = app.descendants(matching: .any)["stage-visual"]
        XCTAssertTrue(visual.waitForExistence(timeout: 20))
        XCTAssertEqual(visual.label, "Grain, moving with the music")
        send(app, "Set the mood")
        let end = Date().addingTimeInterval(20)
        while Date() < end, visual.label != "Aurora, listening to your voice" { usleep(300_000) }
        XCTAssertEqual(visual.label, "Aurora, listening to your voice", "its own line beats the default")
        shot("gouda-own-line-aurora")

        let off = launch(agent: "gouda", appearance: "dark", reply: "visual off\\nsay \\\"Quiet now.\\\"", extra: ["-yuiDemoPickupAfter", "0.6", "-yuiDemoReplyAfter", "4"])
        XCTAssertTrue(off.descendants(matching: .any)["stage-visual"].waitForExistence(timeout: 20))
        send(off, "Go quiet")
        let stop = Date().addingTimeInterval(25)
        while Date() < stop, off.descendants(matching: .any)["stage-visual"].exists { usleep(300_000) }
        XCTAssertFalse(off.descendants(matching: .any)["stage-visual"].exists, "visual off left it up")
        shot("gouda-visual-off")
    }

    // MARK: Helpers

    private func launch(agent: String, appearance: String, reply: String? = nil, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-yuiDemoAccount", "-yuiDemoFirstLaunch", "-yuiStageFirst", "YES", "-yuiAgent", agent,
                    "-appearance", appearance, "-yuiVisualMeter"]
        if let reply { args += ["-yuiDemoReply", reply] }
        app.launchArguments = args + extra
        app.launch()
        return app
    }

    private func send(_ app: XCUIApplication, _ words: String) {
        XCTAssertTrue(app.buttons["stage-type"].waitForExistence(timeout: 15), "no stage")
        app.buttons["stage-type"].tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(words)
        app.buttons["stage-send-text"].tap()
    }

    private func frames(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any)["stage-visual-fps"].value as? String ?? "?"
    }

    private func write(_ file: String, _ text: String) {
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? text.write(to: URL(fileURLWithPath: dir).appending(path: file), atomically: true, encoding: .utf8)
        }
        let a = XCTAttachment(string: text)
        a.name = file
        a.lifetime = .keepAlways
        add(a)
    }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
