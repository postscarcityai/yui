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

    // MARK: keys and chords (step 3)

    private func played(_ e: [String: Any]?) -> [String] { e?["played"] as? [String] ?? [] }

    private func keys(_ appearance: String) {
        launch("keys-\(appearance)", appearance: appearance, lines: [#"say Play along. The lock keeps you in A minor."#, #"keys Am pentatonic "Warm up" +send"#])
        let a4 = app.buttons["key-69"]
        XCTAssertTrue(a4.waitForExistence(timeout: 20), "the keyboard never drew")
        XCTAssertEqual(a4.label, "A4")
        // The scale lock: C# is not in A minor pentatonic, so it is dimmed and silent.
        XCTAssertEqual(app.buttons["key-61"].value as? String, "locked")
        XCTAssertNotEqual(a4.value as? String, "locked")
        sleep(1)
        shot("1-stage")

        a4.tap()
        app.buttons["key-61"].tap()
        XCTAssertEqual(app.staticTexts["keys-played"].label, "A4", "a locked key made a sound")

        // Glide from C4 to E4 along the white keys: C4, D4, E4, and the locked C# and D# in between stay silent.
        app.buttons["key-60"].press(forDuration: 0.15, thenDragTo: app.buttons["key-64"], withVelocity: 300, thenHoldForDuration: 0.1)
        XCTAssertEqual(app.staticTexts["keys-played"].label, "A4 C4 D4 E4")

        // An octave up: the arrows move the keyboard, C5 is the first key.
        app.buttons["keys-octave-up"].tap()
        XCTAssertEqual(app.staticTexts["keys-octave"].label, "C5")
        XCTAssertTrue(app.buttons["key-72"].exists)
        app.buttons["key-81"].tap()

        // The sound picker.
        app.buttons["music-sound-pad"].tap()
        XCTAssertTrue(app.buttons["music-sound-pad"].isSelected)
        app.buttons["key-76"].tap()
        sleep(1)
        shot("2-played")

        app.buttons["keys-send"].tap()
        waitFor("the notes to go out") { !events("keys").isEmpty }
        let e = events("keys").last
        XCTAssertEqual(played(e), ["A4", "C4", "D4", "E4", "A5", "E5"])
        XCTAssertEqual(e?["key"] as? String, "Am")
        XCTAssertEqual(e?["scale"] as? String, "pentatonic")
    }

    func testKeysLight() { keys("light") }
    func testKeysDark() { keys("dark") }

    private func chords(_ appearance: String) {
        launch("chords-\(appearance)", appearance: appearance, lines: [#"say Four chords, every pop song."#, #"chords G I-V-vi-IV "Four chords" +send"#])
        let g = app.buttons["chord-0"]
        XCTAssertTrue(g.waitForExistence(timeout: 20), "the chords never drew")
        XCTAssertEqual(["chord-0", "chord-1", "chord-2", "chord-3"].map { app.buttons[$0].label }, ["G, I", "D, V", "Em, vi", "C, IV"])
        XCTAssertTrue(app.buttons["chords-strum-down"].isSelected)
        sleep(1)
        shot("1-stage")

        g.tap()
        app.buttons["chord-1"].tap()
        app.buttons["chords-strum-up"].tap()
        XCTAssertTrue(app.buttons["chords-strum-up"].isSelected)
        app.buttons["chord-2"].tap()
        app.buttons["chords-strum-off"].tap()
        app.buttons["chord-3"].tap()
        XCTAssertEqual(app.staticTexts["chords-played"].label, "G · D · Em · C")
        sleep(1)
        shot("2-played")

        app.buttons["chords-send"].tap()
        waitFor("the chords to go out") { !events("chords").isEmpty }
        let e = events("chords").last
        XCTAssertEqual(played(e), ["G", "D", "Em", "C"])
        XCTAssertEqual(e?["key"] as? String, "G")
    }

    func testChordsLight() { chords("light") }
    func testChordsDark() { chords("dark") }

    /// A patch moves every chord to the new key and keeps the numerals; a minor
    /// key with flat degrees; chord names skip the theory; strum from the line.
    func testChordsPatchNamesAndMinor() {
        launch("chords-more", appearance: "light", lines: [
            #"say Three ways to write chords."#,
            #"chords C I-V-vi-IV +inline"#, #"~chords key=D"#,
            #">2 chords Am i-bVII-bVI-V7 strum=up"#,
            #">3 chords C|G|Am|F "Campfire""#,
        ])
        XCTAssertTrue(app.buttons["chord-0"].waitForExistence(timeout: 20), "the chords never drew")
        XCTAssertEqual(["chord-0", "chord-1", "chord-2", "chord-3"].map { app.buttons[$0].firstMatch.label }, ["D, I", "A, V", "Bm, vi", "G, IV"])
        app.buttons["chord-2"].firstMatch.tap()
        sleep(1)
        shot("1-patched")
    }

    func testKeysInlineAndPatched() {
        launch("keys-inline", appearance: "dark", lines: [#"say A keyboard in the chat."#, #"keys C major +inline"#, #"~keys key=G octave=3"#])
        XCTAssertTrue(app.buttons["key-48"].waitForExistence(timeout: 20), "the patched keyboard never drew")
        XCTAssertEqual(app.staticTexts["keys-octave"].label, "C3")
        // G major: F is out, F# is in.
        XCTAssertEqual(app.buttons["key-53"].value as? String, "locked")
        XCTAssertNotEqual(app.buttons["key-54"].value as? String, "locked")
        XCTAssertEqual(app.buttons["key-54"].label, "F#3")
        app.buttons["key-55"].tap()
        XCTAssertEqual(app.staticTexts["keys-played"].label, "G3")
        sleep(1)
        shot("1-chat")
    }
}
