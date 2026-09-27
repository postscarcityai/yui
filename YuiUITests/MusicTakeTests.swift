import XCTest

/// Music presets, step 5 (YUI-116): Record on the looper, drums, keys and
/// chords records what the engine plays and sends it like a camera photo
/// (on the demo account `-yuiTakeFake` stands in for the upload, so the event
/// names the sizes it would send). A MIDI keyboard plays the keys; the looper
/// sends MIDI clock. The MIDI side is played by this test runner: a virtual
/// keyboard and a virtual destination in the simulator's MIDI server.
final class MusicTakeTests: XCTestCase {
    private var app: XCUIApplication!
    private var log = ""
    private var tag = ""

    private func launch(_ tag: String, appearance: String, lines: [String], extra: [String] = []) {
        self.tag = tag
        log = FileManager.default.temporaryDirectory.appending(path: "yui116-5-\(tag).jsonl").path
        try? FileManager.default.removeItem(atPath: log)
        app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "wizard", "-appearance", appearance,
                               "-yuiThemeDemo", lines.joined(separator: "\\n"), "-yuiEventLog", log, "-yuiTakeFake", "YES"] + extra
        app.launch()
    }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "take-\(tag)-\(name).png"))
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

    /// The take event: audio and MIDI links, the length, and the MIDI note count.
    private func checkTake(_ e: [String: Any]?, seconds: ClosedRange<Double>, notes: ClosedRange<Int>, file: StaticString = #filePath, line: UInt = #line) {
        let audio = e?["audio"] as? String ?? ""
        let midi = e?["midi"] as? String ?? ""
        XCTAssertTrue(audio.hasSuffix("-bytes.m4a"), "no audio link: \(audio)", file: file, line: line)
        XCTAssertTrue(midi.hasSuffix("-bytes.mid"), "no midi link: \(midi)", file: file, line: line)
        // An AAC file of a few seconds is tens of KB; silence would still be a few KB.
        let bytes = Int(audio.split(separator: "/").last?.split(separator: "-").first ?? "") ?? 0
        XCTAssertGreaterThan(bytes, 8_000, "the audio is suspiciously small", file: file, line: line)
        let secs = (e?["seconds"] as? NSNumber)?.doubleValue ?? 0
        XCTAssertTrue(seconds.contains(secs), "seconds \(secs)", file: file, line: line)
        let n = (e?["notes"] as? NSNumber)?.intValue ?? -1
        XCTAssertTrue(notes.contains(n), "MIDI notes \(n)", file: file, line: line)
    }

    private func record(for seconds: UInt32, playing: () -> Void = {}) {
        let rec = app.buttons["take-record"]
        XCTAssertTrue(rec.waitForExistence(timeout: 10), "no Record button")
        XCTAssertEqual(rec.label, "Record")
        rec.tap()
        waitFor("the take to start", timeout: 5) { app.buttons["take-record"].label == "Stop and send" }
        playing()
        sleep(seconds)
        shot("2-recording")
        app.buttons["take-record"].tap()
    }

    // MARK: record

    private func loop(_ appearance: String) {
        launch("loop-\(appearance)", appearance: appearance,
               lines: [#"say A beat. Record your take."#, #"loop@beat 120 "Boom bap" p=x...x...|..x...x.|xxxxxxxx +play"#])
        XCTAssertTrue(app.buttons["loop-cell-0-0"].waitForExistence(timeout: 20), "the looper never drew")
        sleep(1)
        shot("1-stage")
        // 120 BPM, 8 steps of 8ths: 2 s a bar, a hat on every step.
        record(for: 4)
        waitFor("the take to go out", timeout: 15) { events("loop").contains { $0["audio"] != nil } }
        let e = events("loop").last { $0["audio"] != nil }
        XCTAssertEqual(e?["id"] as? String, "beat")
        XCTAssertEqual(e?["bpm"] as? Int, 120)
        // About 4 s: 8 steps a bar at 4 per second, 3 hits on the downbeat steps: 16 hats, 4 kicks, 4 snares.
        checkTake(e, seconds: 3.5...6, notes: 20...40)
        waitFor("the sent line") { app.staticTexts["take-status"].label.hasPrefix("Take sent") }
        XCTAssertEqual(app.buttons["take-record"].label, "Record again")
        shot("3-sent")
    }

    func testLoopTakeLight() { loop("light") }
    func testLoopTakeDark() { loop("dark") }

    func testKeysTake() {
        launch("keys", appearance: "light", lines: [#"say Play me something."#, #"keys C major "Sketch""#])
        XCTAssertTrue(app.buttons["key-60"].waitForExistence(timeout: 20), "the keyboard never drew")
        record(for: 1) {
            for k in [60, 64, 67, 72] { app.buttons["key-\(k)"].tap() }
        }
        waitFor("the take to go out", timeout: 15) { events("keys").contains { $0["audio"] != nil } }
        checkTake(events("keys").last, seconds: 1...8, notes: 4...4)
        shot("3-sent")
    }

    func testChordsTakeDark() {
        launch("chords", appearance: "dark", lines: [#"say Strum along and record it."#, #"chords G I-V-vi-IV"#])
        XCTAssertTrue(app.buttons["chord-0"].waitForExistence(timeout: 20), "the chords never drew")
        record(for: 1) {
            for i in 0..<4 { app.buttons["chord-\(i)"].tap() }
        }
        waitFor("the take to go out", timeout: 15) { events("chords").contains { $0["audio"] != nil } }
        // Four strums of 3 to 6 strings each.
        checkTake(events("chords").last, seconds: 1...8, notes: 12...24)
        shot("3-sent")
    }

    /// `drums +record`: the pattern take also carries its sound now.
    func testDrumsRecordCarriesAudio() {
        launch("drums", appearance: "light", lines: [#"drums 2x2 "Finger drums" +record bpm=120"#])
        let kick = app.buttons["drum-pad-0"]
        XCTAssertTrue(kick.waitForExistence(timeout: 20), "the pads never drew")
        XCTAssertFalse(app.buttons["take-record"].exists, "two Record buttons on +record drums")
        app.buttons["drums-record"].tap()
        waitFor("the recording to start", timeout: 5) { app.staticTexts["drums-status"].label.hasPrefix("Recording") }
        for _ in 0..<4 { kick.tap(); usleep(400_000) }
        waitFor("the take to go out", timeout: 15) { !events("drums").isEmpty }
        let e = events("drums").last
        XCTAssertEqual(e?["take"] as? Bool, true)
        XCTAssertEqual(e?["rows"] as? [String], ["kick"])
        // Count in (one bar) plus two bars: 6 s at 120. The MIDI file has the
        // 4 kicks and the click the take was played to (GM metronome click).
        checkTake(e, seconds: 5.5...7, notes: 15...18)
    }

    func testTooShort() {
        launch("short", appearance: "light", lines: [#"drums 2x2"#])
        XCTAssertTrue(app.buttons["drum-pad-0"].waitForExistence(timeout: 20))
        app.buttons["take-record"].tap()
        app.buttons["take-record"].tap()
        waitFor("the too-short line") { app.staticTexts["take-status"].label.hasPrefix("Too short") }
        XCTAssertTrue(events("drums").isEmpty)
    }

    // MARK: MIDI

    /// A virtual keyboard plays the keys on screen: keys light, count as
    /// played and follow the keyboard's octave. The looper's clock reaches a
    /// virtual destination at 24 ticks a beat. Both live in the simulator's
    /// MIDI server (made by the app's Debug-only `-yuiMIDIFeed`, since iOS
    /// refuses virtual endpoints to a test runner); the notes and the clock
    /// go through CoreMIDI like a real keyboard's.
    func testMIDIKeyboardAndClock() throws {
        let feed = FileManager.default.temporaryDirectory.appending(path: "yui116-midi-feed.txt").path
        try? FileManager.default.removeItem(atPath: feed)
        try? FileManager.default.removeItem(atPath: feed + ".clock")
        FileManager.default.createFile(atPath: feed, contents: Data())
        func send(_ words: [UInt32]) {
            let h = FileHandle(forWritingAtPath: feed)!
            h.seekToEndOfFile()
            h.write(Data(words.map { String($0, radix: 16) + "\n" }.joined().utf8))
            h.closeFile()
        }
        func clock() -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: feed + ".clock")))) as? [String: Any] ?? [:]
        }

        launch("midi", appearance: "light", lines: [#"say Plug in a keyboard and play."#, #"keys C major "MIDI" +send"#], extra: ["-yuiMIDIFeed", feed])
        let c4 = app.buttons["key-60"]
        XCTAssertTrue(c4.waitForExistence(timeout: 20), "the keyboard never drew")
        waitFor("the app to see the keyboard", timeout: 10) { app.buttons["keys-midi"].label.contains("Test Keyboard") }
        shot("1-connected")

        // Hold C4 and E4: both light (value "down") and count as played.
        send([0x2090_3C64, 0x2090_4064])
        waitFor("C4 to light") { app.buttons["key-60"].value as? String == "down" }
        XCTAssertEqual(app.buttons["key-64"].value as? String, "down")
        shot("2-held")
        send([0x2080_3C00, 0x2090_4000]) // an off, and a velocity-0 on
        waitFor("C4 to let go") { app.buttons["key-60"].value as? String == "" }
        XCTAssertEqual(app.buttons["key-64"].value as? String, "")
        // A note two octaves up moves the keys there.
        send([0x2090_5464, 0x2080_5400]) // C6
        waitFor("the keys to follow to C6") { app.staticTexts["keys-octave"].label == "C6" }
        XCTAssertEqual(app.staticTexts["keys-played"].label, "C4 E4 C6")
        app.buttons["keys-send"].tap()
        waitFor("the notes to go out") { !events("keys").isEmpty }
        XCTAssertEqual(events("keys").last?["played"] as? [String], ["C4", "E4", "C6"])
        shot("3-played")

        // Clock: a loop at 120 for about 3 s: 24 ticks a beat is 48 a second.
        app.terminate()
        try? FileManager.default.removeItem(atPath: feed + ".clock")
        launch("clock", appearance: "light", lines: [#"say Your drum machine follows this."#, #"loop 120 p=x...x...|..x...x."#], extra: ["-yuiMIDIFeed", feed])
        let play = app.buttons["loop-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        play.tap()
        sleep(3)
        play.tap()
        sleep(1)
        let c = clock()
        let starts = c["starts"] as? Int ?? 0, ticks = c["ticks"] as? Int ?? 0, stops = c["stops"] as? Int ?? 0
        let gap = (c["gap"] as? NSNumber)?.doubleValue ?? 0
        print("MIDI clock: \(starts) start, \(ticks) ticks, \(stops) stop, median gap \(gap * 1000) ms")
        XCTAssertEqual(starts, 1, "one Start")
        XCTAssertGreaterThanOrEqual(stops, 1, "a Stop")
        XCTAssertTrue((100...220).contains(ticks), "ticks \(ticks) in about 3 s")
        XCTAssertEqual(gap, 1.0 / 48, accuracy: 0.001, "tick spacing \(gap) s")
    }
}
