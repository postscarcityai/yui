import XCTest

/// Stage first (YUI-119 step 2): Yui lives on the full screen. A send puts the
/// stage up at once, working; the reply plays as chunks, a line and a picture
/// each; the questions come last with one Send; the chat is the record, top
/// right, with the way back to the full screen. The demo account answers with
/// the mock's "release that" reply (yuigui playground?demo=stage-first), no network.
/// Screenshots go to `YUI_SHOTS` when set, and always into the result bundle.
final class StageFirstTests: XCTestCase {
    static let releaseReply = [
        "say \"0.3.2 is building. On TestFlight in about 40 minutes.\"",
        "shapes w=12 h=6 caption=\"Build, checks, TestFlight. You get a ping when it lands.\"",
        "shape@b box Build at=2,3 +fill +pulse",
        "shape arrow from=b to=c",
        "shape@c box Checks at=6,3 +dash",
        "shape arrow from=c to=t",
        "shape@t pill TestFlight at=10,3 size=3.2,1.4 tone=mint +dash",
        "say \"Keys and chords ride along.\"",
        "shapes w=12 h=7 caption=\"A scale to play, a loop of chords to strum.\"",
        "shape box A at=1.5,2.6 size=1.3,3.6 +fill",
        "shape box B at=3,2.6 size=1.3,3.6 tone=mute",
        "shape box C at=4.5,2.6 size=1.3,3.6 +fill",
        "shape pill \"I V vi IV\" at=6,6 size=5,1.2 tone=mint +fill +grow",
        "say \"The faster Send tap waits for 0.3.3.\"",
        "sketch \"In 0.3.2\" frame=window",
        "row \"Keys and chords\" +hi",
        "row \"Real drum sounds\" +hi",
        "row \"Faster Send tap\" +x note=\"not done yet\"",
        "plan@before \"Before I go\" submit=Send",
        "choose@ping \"Ping you when it lands?\" \"Yes, ping me\"|\"Only if it breaks\"",
        "choose@try \"What do you want to try first?\" Keys|Chords|Drums",
        "end",
    ].joined(separator: "\\n")

    static let latest = [
        "say \"Yes. Build 160, the newest.\"",
        "shapes w=10 h=6 caption=\"Your iPad is on 135. Update it in TestFlight.\"",
        "shape@p box \"iPhone 160\" at=3,3 size=3,4 tone=mint +fill +grow",
        "shape@i box \"iPad 135\" at=7.4,3 size=3.6,3 tone=mute +dash",
    ].joined(separator: "\\n")

    func testReleaseThatPlaysAsChunksThenAsksOnceLight() throws { try playRelease(appearance: "light") }
    func testReleaseThatPlaysAsChunksThenAsksOnceDark() throws { try playRelease(appearance: "dark") }

    /// A status question gets one screen: the answer and its picture, no arrows.
    func testAStatusAnswerIsOneScreen() throws {
        let app = launch("light", reply: Self.latest)
        send(app, "Am I on the latest build?")
        XCTAssertTrue(line(app, "Yes. Build 160").waitForExistence(timeout: 15), "the answer never played")
        XCTAssertFalse(app.buttons["stage-next"].exists, "one chunk should have no arrows")
        XCTAssertFalse(app.otherElements["stage-segments"].exists)
        sleep(1)
        shot("latest-answer", "light")
    }

    private func playRelease(appearance: String) throws {
        let app = launch(appearance, reply: Self.releaseReply)

        // At rest: the greeting, the agent top left, the chat top right, mic T and + bottom right.
        XCTAssertTrue(app.descendants(matching: .any)["stage-greeting"].waitForExistence(timeout: 15), "no stage at launch")
        for id in ["stage-settings", "stage-agents", "stage-record", "stage-mic", "stage-type", "stage-attach"] {
            XCTAssertTrue(app.descendants(matching: .any)[id].exists, "\(id) is missing")
        }
        let mic = app.buttons["stage-mic"].frame, type = app.buttons["stage-type"].frame
        XCTAssertGreaterThan(mic.minX, type.minX, "the mic is not bottom right")
        XCTAssertEqual(mic.width, 58, accuracy: 1, "mic size")
        shot("1-greeting", appearance)

        // T opens the field; the send puts the stage straight into working.
        app.buttons["stage-type"].tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "T did not open the field")
        field.typeText("OK, yeah go ahead and release that.")
        shot("2-typing", appearance)
        app.buttons["stage-send-text"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["stage-working"].waitForExistence(timeout: 3), "no working state after send")
        XCTAssertTrue(app.descendants(matching: .any)["stage-you"].exists, "their words are not at the top")
        shot("3-working", appearance)

        // The reply plays: three chunks, a line and a picture each, then the questions.
        XCTAssertTrue(line(app, "0.3.2 is building").waitForExistence(timeout: 20), "chunk 1 never showed")
        // The rest streams in, a line every 220 ms: three chunks and the questions.
        let all4 = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'stage-segments' AND label == 'Part 1 of 4'")).firstMatch
        XCTAssertTrue(all4.waitForExistence(timeout: 15), "the reply never grew to four parts")
        shot("4-chunk-1", appearance)
        app.buttons["stage-next"].tap()
        XCTAssertTrue(line(app, "Keys and chords ride along").waitForExistence(timeout: 3))
        shot("5-chunk-2", appearance)
        app.buttons["stage-next"].tap()
        XCTAssertTrue(line(app, "The faster Send tap").waitForExistence(timeout: 3))
        shot("6-chunk-3", appearance)
        // Back works too.
        app.buttons["stage-back"].tap()
        XCTAssertTrue(line(app, "Keys and chords ride along").waitForExistence(timeout: 3))
        app.buttons["stage-next"].tap()
        app.buttons["stage-next"].tap()

        // Every question on one screen, one Send.
        XCTAssertTrue(app.descendants(matching: .any)["stage-questions"].waitForExistence(timeout: 3), "no questions screen")
        let send = app.buttons["stage-send"]
        XCTAssertTrue(send.exists)
        XCTAssertFalse(send.isEnabled, "Send before any answer")
        XCTAssertTrue(app.buttons["Yes, ping me"].exists && app.buttons["Keys"].exists, "both questions should show at once")
        shot("7-questions", appearance)
        app.buttons["Yes, ping me"].tap()
        app.buttons["Keys"].tap()
        XCTAssertTrue(send.isEnabled)
        shot("8-answered", appearance)
        send.tap()
        XCTAssertTrue(text(app, "Sent. It's in the chat.").waitForExistence(timeout: 5), "Send did not go")

        // The chat is the record: the plan's answers and every chunk are there.
        app.buttons["stage-record"].tap()
        XCTAssertTrue(app.buttons["back-to-stage"].waitForExistence(timeout: 5), "the record has no way back")
        XCTAssertTrue(text(app, "Ping you when it lands? Yes, ping me").waitForExistence(timeout: 5), "the answers are not in the record")
        sleep(1)
        shot("9-record", appearance)
        app.buttons["back-to-stage"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["stage-first"].waitForExistence(timeout: 5), "the stage did not come back")
    }

    // MARK: Helpers

    private func launch(_ appearance: String, reply: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "yui",
                               "-appearance", appearance, "-yuiDemoReply", reply,
                               "-yuiDemoPickupAfter", "0.5", "-yuiDemoReplyAfter", "3.5",
                               "-yuiDemoDoing", "\"Starting the 0.3.2 release\" 1/2|\"Checking what is ready\" 2/2"]
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

    private func line(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "identifier == 'stage-line' AND label BEGINSWITH %@", prefix)).firstMatch
    }

    private func text(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func shot(_ name: String, _ appearance: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "stage-first-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "stage-first-\(appearance)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }
}
