import XCTest

/// The visual listens (YUI-125): it moves with your voice while you talk, with the
/// agent's voice while it speaks, and with the music tools. The level the shader got
/// (after the look's envelope, the loudest in the last second) comes from
/// `-yuiVisualMeter`. Numbers and shots go to `YUI_SHOTS` when set.
@MainActor
final class VisualListensUITests: XCTestCase {
    /// Talking: the push-to-talk listening state (a fake voice, the simulator has no mic
    /// in CI) moves the orb; silence leaves it still.
    func testItMovesWithYourVoice() throws {
        let quiet = launch(reply: "say Done.", extra: ["-yuiDemoVisual", "orb"])
        XCTAssertTrue(visual(quiet).waitForExistence(timeout: 15))
        sleep(3)
        let still = level(quiet)
        XCTAssertLessThan(still, 0.05, "nobody talking: \(fps(quiet))")
        quiet.terminate()

        let app = launch(reply: "say Done.", extra: ["-yuiDemoVisual", "orb", "-yuiPTTDemo", "Is my morning free tomorrow?"])
        XCTAssertTrue(visual(app).waitForExistence(timeout: 15))
        sleep(3)
        let talking = level(app)
        shot("voice-orb-talking")
        XCTAssertGreaterThan(talking, 0.3, "talking should move it: \(fps(app))")
        write("voice.txt", "orb, nobody talking: level \(still)\norb, you talking: \(fps(app))\n")
    }

    /// The looper: play moves the waves, stop lets them settle.
    func testItMovesWithTheMusic() throws {
        let app = launch(reply: #"visual waves react=music\nloop 96 "Boom bap" p=x...x.x.|....x...|..x...x.|xxxxxxxx"#,
                         agent: "coach")
        send(app, "Give me a beat")
        let play = app.buttons["loop-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 25), "the looper never drew")
        XCTAssertEqual(visual(app).label, "Waves, moving with the music")
        sleep(2)
        let before = level(app)
        play.tap()
        sleep(4)
        let playing = level(app)
        let playingFps = fps(app)
        shot("music-waves-playing")
        XCTAssertGreaterThan(playing, 0.3, "the loop should move it: \(playingFps)")
        XCTAssertEqual(play.label, "Stop")
        play.tap()
        XCTAssertEqual(play.label, "Play", "the loop stopped")
        var trail: [String] = []
        for _ in 0..<5 { sleep(1); trail.append(String(format: "%.2f", level(app))) }
        let after = level(app)
        print("music after stop: \(trail)")
        XCTAssertLessThan(after, 0.1, "stopped: it settles (\(fps(app)))")
        write("music.txt", "waves, before play: level \(before)\nwaves, loop playing: \(playingFps)\nwaves, stopped: level \(after)\n")
    }

    /// The agent's spoken answer: a narrate line spoken aloud moves the bloom.
    func testItMovesWithTheAgentsVoice() throws {
        let app = launch(reply: #"visual bloom\nnarrate "Hello"\ncard "Hi" "I listen while you talk, and I move when I talk back."\nend"#,
                         agent: "zen")
        send(app, "Say hi")
        let play = app.buttons.matching(identifier: "Play").firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 25), "the narrate never drew")
        print("play buttons: \(app.buttons.matching(identifier: "Play").count)")
        sleep(2)
        let before = level(app)
        play.tap()
        var speaking = 0.0
        for _ in 0..<8 { sleep(1); speaking = max(speaking, level(app)) }
        shot("voice-bloom-agent-speaking")
        XCTAssertGreaterThan(speaking, 0.3, "the agent's voice should move it: \(fps(app))")
        write("agent-voice.txt", "bloom, before the agent speaks: level \(before)\nbloom, agent speaking: loudest level \(speaking), \(fps(app))\n")
    }

    // MARK: Helpers

    private func launch(reply: String, agent: String = "yui", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", agent,
                               "-appearance", "dark", "-yuiDemoReply", reply, "-yuiVisualMeter",
                               "-yuiDemoPickupAfter", "0.6", "-yuiDemoReplyAfter", "1.5"] + extra
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

    private func visual(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["stage-visual"] }

    /// "visual 60 fps, app 60 fps, level 0.43, 812 frames"
    private func fps(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any)["stage-visual-fps"].value as? String ?? "?"
    }

    private func level(_ app: XCUIApplication) -> Double {
        let words = fps(app)
        guard let r = words.range(of: "level ") else { return -1 }
        return Double(words[r.upperBound...].prefix(while: { $0.isNumber || $0 == "." })) ?? -1
    }

    private func write(_ file: String, _ text: String) {
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? text.write(to: URL(fileURLWithPath: dir).appending(path: "listens-\(file)"), atomically: true, encoding: .utf8)
        }
        let a = XCTAttachment(string: text)
        a.name = "listens-\(file)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "listens-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "listens-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }
}
