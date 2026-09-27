import XCTest

/// Stage motion (YUI-120 step 2, YUI-123 step 4): the stage moves with the agent.
/// The same turn on two agents: Coach (snappy: quick, sharp, slides in, ticks) and
/// Wizard with a look said in words (heavy and punchy: quick, heavy, drops in,
/// beats). Moods from the turn: think, looking (a sweep), making (a build-up),
/// the found beat, the chunk, the questions one by one; a failed turn shakes,
/// goes grey and offers Try again; Reduce Motion plays the same turn still.
/// Screenshots go to `YUI_SHOTS` when set, and always into the result bundle.
final class StageMotionUITests: XCTestCase {
    static let reply = [
        "say \"Tuesday at 10 is dry. Wind under 8.\"",
        "shapes w=12 h=6 caption=\"Rain until Monday night, clear from Tuesday.\"",
        "shape@m box Mon at=2,3 tone=mute +dash",
        "shape@t box Tue at=6,3 tone=mint +fill +grow",
        "shape@w box Wed at=10,3 tone=mint +fill",
        "plan@go \"Book it?\" submit=Send",
        "choose@when \"Which slot?\" \"Tue 10:00\"|\"Tue 14:00\"",
        "choose@who \"Invite Mick?\" Yes|No",
        "end",
    ].joined(separator: "\\n")

    /// Unquoted: a launch argument that starts with a quote is read as a plist string.
    static let doing = "Checking the forecast 1/3|Drafting the plan 2/3|Found a dry window 3/3"

    func testSnappyCoach() throws { try play(agent: "coach", look: nil, name: "coach-snappy") }

    func testWizardSaidHeavyAndPunchy() throws {
        try play(agent: "wizard", look: "pace=quick ease=heavy enter=drop pulse=beat", name: "wizard-heavy-punchy")
    }

    func testReduceMotionPlaysTheSameTurnStill() throws {
        try play(agent: "coach", look: nil, name: "reduce-motion", reduce: true)
    }

    /// A reply of nothing but error lines: a small shake, grey, and Try again.
    func testAFailedTurnOffersTryAgain() throws {
        let app = launch(agent: "yui", look: nil, reply: "theme app wobble", doing: nil, reduce: false)
        send(app, "Book the dry day")
        let again = app.buttons["stage-try-again"]
        XCTAssertTrue(again.waitForExistence(timeout: 15), "no Try again on a failed turn")
        XCTAssertTrue(text(app, "That didn't go through.").exists)
        shot("error", "light")
        // The demo fails again at once, so the working state can come and go before
        // a query sees it: the record's new count growing is the proof it sent.
        let record = app.buttons["stage-record"]
        let before = record.value as? String ?? ""
        again.tap()
        let sent = NSPredicate { _, _ in
            app.descendants(matching: .any)["stage-working"].exists || (record.value as? String ?? "") != before
        }
        let wait = XCTNSPredicateExpectation(predicate: sent, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [wait], timeout: 8), .completed, "Try again did not send")
    }

    private func play(agent: String, look: String?, name: String, reduce: Bool = false) throws {
        let app = launch(agent: agent, look: look, reply: Self.reply, doing: Self.doing, reduce: reduce)
        send(app, "Find me a dry day to fly the drone")
        let working = app.descendants(matching: .any)["stage-working"]
        XCTAssertTrue(working.waitForExistence(timeout: 5), "no working state after send")
        shot("\(name)-1-think", "light")
        // The doing words drive the mark: looking, then making, then the found beat.
        for (words, step) in [("Checking the forecast", "2-looking"), ("Drafting the plan", "3-making"), ("Found a dry window", "4-found")] {
            let got = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", words), object: working)
            XCTAssertEqual(XCTWaiter.wait(for: [got], timeout: 8), .completed, "no step \(words): \(working.label)")
            shot("\(name)-\(step)", "light")
        }
        // The reply plays: the chunk, in the look's enter.
        let line = app.staticTexts.matching(NSPredicate(format: "identifier == 'stage-line' AND label BEGINSWITH 'Tuesday at 10'")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 15), "the chunk never played")
        sleep(1)
        shot("\(name)-5-chunk", "light")
        let next = app.buttons["stage-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        next.tap()
        // The questions, one by one, then one Send.
        XCTAssertTrue(app.descendants(matching: .any)["stage-questions"].waitForExistence(timeout: 5), "no questions screen")
        XCTAssertTrue(app.buttons["Tue 10:00"].waitForExistence(timeout: 3) && app.buttons["Yes"].waitForExistence(timeout: 3),
                      "both questions should come on")
        shot("\(name)-6-questions", "light")
        // Going back comes on from the other side.
        app.buttons["stage-back"].tap()
        XCTAssertTrue(line.waitForExistence(timeout: 5), "back did not bring the chunk")
    }

    // MARK: Helpers

    private func launch(agent: String, look: String?, reply: String, doing: String?, reduce: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", agent,
                    "-appearance", "light", "-yuiDemoReply", reply,
                    "-yuiDemoPickupAfter", "0.6", "-yuiDemoReplyAfter", doing == nil ? "1.2" : "8"]
        if let doing { args += ["-yuiDemoDoing", doing] }
        if let look { args += ["-yuiDemoLook", look] }
        if reduce { args.append("-yuiReduceMotion") }
        app.launchArguments = args
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

    private func text(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", prefix)).firstMatch
    }

    private func shot(_ name: String, _ appearance: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "stage-motion-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "stage-motion-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }
}
