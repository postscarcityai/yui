import XCTest

/// Music presets, step 2 (YUI-116): `loop` and `drums` drawn from the parser's
/// ops and played by YuiSound. The looper edits, plays and sends its pattern;
/// the pads play on touch down; a drum take records and comes back in the
/// loop's shape. Screenshots go to `YUI_SHOTS` when set.
final class MusicTests: XCTestCase {
    private var app: XCUIApplication!
    private var log = ""
    private var tag = ""

    private func launch(_ tag: String, appearance: String, lines: [String]) {
        self.tag = tag
        log = FileManager.default.temporaryDirectory.appending(path: "yui116-\(tag).jsonl").path
        try? FileManager.default.removeItem(atPath: log)
        app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "wizard", "-appearance", appearance,
                               "-yuiThemeDemo", lines.joined(separator: "\\n"), "-yuiEventLog", log]
        app.launch()
    }

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

    private func events(_ preset: String) -> [[String: Any]] {
        let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }.filter { $0["preset"] as? String == preset }
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 10, _ ok: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if ok() { return }; usleep(150_000) }
        XCTFail("timed out waiting for \(what)")
    }

    private func loop(_ appearance: String) {
        launch("loop-\(appearance)", appearance: appearance,
               lines: [#"say A beat for you. Change anything."#, #"loop 96 "Boom bap" p=x...x.x.|....x...|..x...x.|xxxxxxxx"#])
        let cell = app.buttons["loop-cell-1-2"]
        XCTAssertTrue(cell.waitForExistence(timeout: 20), "the looper never drew")
        XCTAssertEqual(app.buttons["loop-cell-0-0"].value as? String, "on")
        XCTAssertEqual(cell.value as? String, "off")
        sleep(1)
        shot("1-stage")

        // Edit while it plays: a snare on step 3, faster, swing.
        app.buttons["loop-play"].tap()
        cell.tap()
        XCTAssertEqual(cell.value as? String, "on")
        app.buttons["loop-faster"].tap()
        app.buttons["loop-swing"].tap()
        sleep(1)
        shot("2-playing")
        app.buttons["loop-play"].tap()

        app.buttons["loop-send"].tap()
        waitFor("the pattern to go out") { !events("loop").isEmpty }
        let e = events("loop").last
        XCTAssertEqual(e?["bpm"] as? Int, 98)
        XCTAssertEqual(e?["swing"] as? Int, 25)
        XCTAssertEqual(e?["steps"] as? Int, 8)
        XCTAssertEqual((e?["p"] as? [String])?.prefix(4), ["x...x.x.", "..x.x...", "..x...x.", "xxxxxxxx"])
        XCTAssertEqual((e?["rows"] as? [String])?.first, "kick")
    }

    func testLoopLight() { loop("light") }
    func testLoopDark() { loop("dark") }

    private func drums(_ appearance: String) {
        launch("drums-\(appearance)", appearance: appearance, lines: [#"drums 2x2 "Finger drums" +record bpm=120"#])
        let kick = app.buttons["drum-pad-0"]
        XCTAssertTrue(kick.waitForExistence(timeout: 20), "the pads never drew")
        XCTAssertEqual(kick.label, "kick pad")
        XCTAssertEqual(app.buttons["drum-pad-3"].label, "hat pad")
        sleep(1)
        shot("1-stage")

        // Record: one bar of count in (2 s at 120), then hit through the two bars.
        app.buttons["drums-record"].tap()
        waitFor("the recording to start", timeout: 5) { app.staticTexts["drums-status"].label.hasPrefix("Recording") }
        for _ in 0..<4 { kick.tap(); app.buttons["drum-pad-3"].tap(); usleep(250_000) }
        shot("2-recording")
        waitFor("the take to go out", timeout: 10) { !events("drums").isEmpty }
        let e = events("drums").last
        XCTAssertEqual(e?["take"] as? Bool, true)
        XCTAssertEqual(e?["bpm"] as? Int, 120)
        XCTAssertEqual(e?["steps"] as? Int, 32)
        XCTAssertEqual(e?["rows"] as? [String], ["kick", "hat"])
        XCTAssertEqual((e?["p"] as? [String])?.first?.count, 32)
        XCTAssertEqual(app.staticTexts["drums-status"].label, "Take sent.")
        shot("3-sent")
    }

    func testDrumsLight() { drums("light") }
    func testDrumsDark() { drums("dark") }

    /// Inline in the chat: `+inline` keeps them off the stage; a 4x4 gets the whole kit.
    func testInline() {
        launch("inline", appearance: "light",
               lines: [#"say Two to try."#, #"drums 4x4 +inline"#, #"loop 100 sound=bell rows=C5|A4|G4|E4 p=x.......|..x.....|....x...|......x. +inline"#])
        XCTAssertTrue(app.buttons["drum-pad-15"].waitForExistence(timeout: 20), "the 4x4 never drew")
        XCTAssertEqual(app.buttons["drum-pad-15"].label, "bell pad")
        XCTAssertTrue(app.buttons["loop-cell-3-6"].exists, "the note looper is missing")
        app.buttons["drum-pad-5"].tap()
        sleep(1)
        shot("1-chat")
    }
}
