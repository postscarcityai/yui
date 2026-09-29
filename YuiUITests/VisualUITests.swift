import XCTest

/// The visual (YUI-124 step 2): a `visual` line in a reply puts a Metal shader behind
/// the stage. Alone (the agent working) it runs at 60 fps and full strength; behind a
/// chunk at 30 fps, dimmed, with a scrim under the words; Reduce Motion and Low Power
/// draw one still frame. Frame numbers come from `-yuiVisualMeter` (what the visual
/// drew and what the app's display link got, per second). Screenshots and the numbers
/// go to `YUI_SHOTS` when set, and always into the result bundle.
final class VisualUITests: XCTestCase {
    static let looks = ["orb", "aurora", "waves", "grain", "bloom"]
    /// Each look in its agent's color, like the playground's samples.
    static let agents = ["orb": "yui", "aurora": "zen", "waves": "coach", "grain": "wizard", "bloom": "coach"]

    /// The same turn with each look, light and dark: working (alone), then the chunk (behind words).
    func testEveryLookInLightAndDark() throws {
        var numbers: [String] = []
        for look in Self.looks {
            for appearance in ["light", "dark"] {
                let app = launch(agent: Self.agents[look]!, reply: "visual \(look)\\nsay \"Tuesday at 10 is dry. Wind under 8.\"",
                                 appearance: appearance, level: 0.55, extra: ["-yuiDemoVisual", look])
                send(app, "Find me a dry day")
                let visual = app.descendants(matching: .any)["stage-visual"]
                XCTAssertTrue(visual.waitForExistence(timeout: 10), "\(look): no visual")
                XCTAssertTrue(app.descendants(matching: .any)["stage-working"].waitForExistence(timeout: 5))
                sleep(3)
                XCTAssertEqual(visual.value as? String, "60 fps", "\(look) alone runs at 60")
                let alone = frames(app)
                shot("\(look)-\(appearance)-1-alone")
                let line = app.staticTexts.matching(NSPredicate(format: "identifier == 'stage-line'")).firstMatch
                XCTAssertTrue(line.waitForExistence(timeout: 15), "\(look): the chunk never played")
                sleep(3)
                XCTAssertEqual(visual.value as? String, "30 fps", "\(look) behind words runs at 30")
                let behind = frames(app)
                shot("\(look)-\(appearance)-2-behind-words")
                numbers.append("\(look) \(appearance) | alone: \(alone) | behind words: \(behind)")
                app.terminate()
            }
        }
        write("frames.txt", numbers.joined(separator: "\n") + "\n")
    }

    /// A soak for the memory table: the visual alone at 60 fps for `YUI_VISUAL_SOAK` seconds
    /// (default 5) while scripts or Instruments sample the app. Frames go to the report.
    func testSoakAlone() throws {
        let secs = UInt32(ProcessInfo.processInfo.environment["YUI_VISUAL_SOAK"] ?? "") ?? 5
        let app = launch(agent: "yui", reply: "say Done.", appearance: "dark", level: 0.5, after: Double(secs + 30), extra: ["-yuiDemoVisual", "orb"])
        send(app, "Take your time")
        XCTAssertTrue(app.descendants(matching: .any)["stage-visual"].waitForExistence(timeout: 10))
        sleep(secs)
        write("frames-soak.txt", "orb alone, \(secs) s: \(frames(app))\n")
    }

    /// A paired agent starts on the soft default orb (YUI-180); the reply's line changes it, and the label says so.
    func testTheReplysLinePutsItUp() throws {
        let app = launch(agent: "zen", reply: "visual aurora tone=mint react=music\\nsay \"Winding down.\"", appearance: "dark")
        send(app, "Help me wind down")
        XCTAssertTrue(app.descendants(matching: .any)["stage-working"].waitForExistence(timeout: 5))
        let visual = app.descendants(matching: .any)["stage-visual"]
        XCTAssertTrue(visual.waitForExistence(timeout: 5), "an agent has its quiet default before a reply")
        XCTAssertEqual(visual.label, "Orb, listening to your voice")
        XCTAssertTrue(NSPredicate(format: "label == %@", "Aurora, moving with the music")
            .evaluate(with: visual) || waitLabel(visual, "Aurora, moving with the music"), "the reply's visual line put nothing up")
        XCTAssertTrue(app.staticTexts["Winding down."].waitForExistence(timeout: 5), "the words play over it")
    }

    func testReduceMotionDrawsOneStillFrame() throws { try still(flag: "-yuiReduceMotion", name: "reduce-motion") }

    func testLowPowerDrawsOneStillFrame() throws { try still(flag: "-yuiLowPower", name: "low-power") }

    private func still(flag: String, name: String) throws {
        let app = launch(agent: "zen", reply: "visual aurora\\nsay \"Breathe in for four.\"", appearance: "dark", extra: [flag])
        send(app, "Breathe with me")
        let visual = app.descendants(matching: .any)["stage-visual"]
        XCTAssertTrue(visual.waitForExistence(timeout: 15))
        XCTAssertEqual(visual.value as? String, "Still")
        sleep(2)
        let first = drawn(app)
        sleep(3)
        let later = drawn(app)
        XCTAssertLessThanOrEqual(later - first, 2, "\(name): the still kept drawing (\(first) -> \(later))")
        shot("aurora-dark-\(name)-still")
        write("frames-\(name).txt", "\(name): \(frames(app)) (\(later - first) frames in 3 s)\n")
    }

    // MARK: Helpers

    private func launch(agent: String, reply: String, appearance: String, level: Double? = nil, after: Double = 6, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", agent,
                    "-appearance", appearance, "-yuiDemoReply", reply, "-yuiVisualMeter",
                    "-yuiDemoPickupAfter", "0.6", "-yuiDemoReplyAfter", String(after)]
        if let level { args += ["-yuiVisualLevel", String(level)] }
        app.launchArguments = args + extra
        app.launch()
        return app
    }

    private func waitLabel(_ e: XCUIElement, _ label: String, timeout: TimeInterval = 15) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if e.label == label { return true }; usleep(300_000) }
        return false
    }

    private func send(_ app: XCUIApplication, _ words: String) {
        XCTAssertTrue(app.buttons["stage-type"].waitForExistence(timeout: 15), "no stage")
        app.buttons["stage-type"].tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(words)
        app.buttons["stage-send-text"].tap()
    }

    /// "visual 60 fps, app 60 fps, 812 frames"
    private func frames(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any)["stage-visual-fps"].value as? String ?? "?"
    }

    private func drawn(_ app: XCUIApplication) -> Int {
        let words = frames(app)
        return Int(words.split(separator: ",").last?.split(separator: " ").first ?? "") ?? -1
    }

    private func write(_ file: String, _ text: String) {
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? text.write(to: URL(fileURLWithPath: dir).appending(path: "visual-\(file)"), atomically: true, encoding: .utf8)
        }
        let a = XCTAttachment(string: text)
        a.name = "visual-\(file)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "visual-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "visual-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }
}
