import XCTest

/// Chris, TestFlight APO8y7eU_NQKRDyLpUdwhX0: the stage said "Anything else? Everything so far is in
/// the chat" while the agent was still working, so the turn read as half done. The end screen shows
/// only for a finished turn: from the send to the reply landing, the stage keeps the working state.
final class StageInFlightTests: XCTestCase {
    func testNoEndScreenFromSendToReplyDark() throws { try run("dark") }
    func testNoEndScreenFromSendToReplyLight() throws { try run("light") }

    private func run(_ appearance: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "yui",
                               "-appearance", appearance, "-yuiDemoReply", "say \"Here you go.\"",
                               "-yuiDemoPickupAfter", "2", "-yuiDemoReplyAfter", "9"]
        app.launch()
        XCTAssertTrue(app.buttons["stage-type"].waitForExistence(timeout: 20), "no stage")
        app.buttons["stage-type"].tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("What is on the board?")
        app.buttons["stage-send-text"].tap()

        let sentAt = Date()
        let end = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Anything else?'"))
        let answer = app.staticTexts.matching(NSPredicate(format: "identifier == 'stage-line' AND label BEGINSWITH 'Here you go'")).firstMatch
        let working = app.descendants(matching: .any)["stage-working"]
        XCTAssertTrue(working.waitForExistence(timeout: 3), "sending shows no working state")
        shot("working", appearance)

        // Every beat until the reply lands: the end screen never shows.
        let deadline = Date().addingTimeInterval(25)
        var sawWorking = 0
        while !answer.exists, Date() < deadline {
            // Sustained, not one stale accessibility snapshot: still there a beat later.
            if end.count > 0, { usleep(300_000); return end.count > 0 }() {
                let elapsed = Date().timeIntervalSince(sentAt)
                shot("end-showed", appearance)
                XCTFail("the end screen showed while the reply was still owed, \(elapsed)s after the send; answer=\(answer.exists) working=\(working.exists)")
                break
            }
            if working.exists { sawWorking += 1 }
            usleep(250_000)
        }
        XCTAssertTrue(answer.exists, "the reply never landed")
        XCTAssertGreaterThan(sawWorking, 10, "the stage did not stay on working until the reply")
        XCTAssertEqual(end.count, 0, "the end screen is up over the reply")
        shot("answered", appearance)
    }

    private func shot(_ name: String, _ appearance: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "in-flight-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "in-flight-\(appearance)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }
}
