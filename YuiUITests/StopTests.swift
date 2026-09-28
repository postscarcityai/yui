import XCTest

/// Stop (YUI-190). Chris on TestFlight, Basil saying "Got it, working out the macros": "I actually
/// do want to be able to cancel... I'm leaning towards the main screen." While the agent works the
/// mic is a stop square; a tap stops it, the stage goes still, the record says Stopped, the late
/// answer never lands, and the mic is back for the next thing. Demo account, no network; the demo
/// answer takes 8 seconds so there is time to stop it. Shots go to `YUI_SHOTS` when set.
final class StopUITests: XCTestCase {
    static let reply = "say \"Here is your whole week, planned.\""

    func testStopLight() throws { try stop("light") }
    func testStopDark() throws { try stop("dark") }

    private func stop(_ appearance: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "basil",
                               "-appearance", appearance, "-yuiDemoReply", Self.reply,
                               "-yuiDemoPickupAfter", "0.5", "-yuiDemoReplyAfter", "8",
                               "-yuiDemoDoing", "Working out the macros 1/2|Checking your day 2/2"]
        app.launch()
        let mic = app.buttons["stage-mic"], stop = app.buttons["stage-stop"]
        XCTAssertTrue(mic.waitForExistence(timeout: 15), "no mic on the stage")
        XCTAssertFalse(stop.exists, "a stop square with nothing running")

        app.buttons["stage-type"].tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Plan my meals for the week")
        app.buttons["stage-send-text"].tap()

        // Working: the mic is a stop square, in the mic's place, at the mic's size.
        XCTAssertTrue(app.descendants(matching: .any)["stage-working"].firstMatch.waitForExistence(timeout: 5), "not working")
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "no stop square while the agent works")
        XCTAssertFalse(mic.exists, "the mic and the stop square both show")
        XCTAssertEqual(stop.label, "Stop", "VoiceOver reads Stop")
        XCTAssertEqual(stop.frame.width, 58, accuracy: 1, "the stop square is the mic's size")
        XCTAssertGreaterThan(stop.frame.maxX, app.frame.width - 40, "the stop square is not under the thumb")
        XCTAssertTrue(app.buttons["stage-type"].exists, "T stays, to type the next thing")
        sleep(2)
        shot("1-working", appearance)

        stop.tap()
        // Idle at once: the stage is still, the mic is back, nothing more comes.
        XCTAssertTrue(app.descendants(matching: .any)["stage-stopped"].firstMatch.waitForExistence(timeout: 3), "the stage did not stop")
        XCTAssertTrue(mic.waitForExistence(timeout: 3), "the mic did not come back")
        XCTAssertFalse(stop.exists, "the stop square stayed")
        XCTAssertFalse(app.descendants(matching: .any)["stage-working"].firstMatch.exists, "still working after Stop")
        sleep(1)
        shot("2-stopped", appearance)

        // Past the time the answer would have come: it never lands.
        sleep(9)
        XCTAssertFalse(app.staticTexts["Here is your whole week, planned."].exists, "the late answer landed on the stage")
        XCTAssertTrue(app.descendants(matching: .any)["stage-stopped"].firstMatch.exists)

        // The record keeps it quietly.
        app.buttons["stage-record"].tap()
        let note = app.descendants(matching: .any)["stopped-note"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5), "no Stopped in the record")
        XCTAssertFalse(app.staticTexts["Here is your whole week, planned."].exists, "the late answer landed in the record")
        XCTAssertTrue(app.buttons["record-mic"].exists, "the record's mic is back too")
        sleep(1)
        shot("3-record", appearance)
    }

    private func shot(_ name: String, _ appearance: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "stop-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "stop-\(appearance)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }
}
