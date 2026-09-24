import XCTest

/// Answers can change (YUI-12): choose, pick, ask and slide stay live after the
/// first answer, and every later answer goes back with `changed: true`. `+lock`
/// freezes a component. Runs on the demo account, no network. Screenshots go to
/// `YUI_SHOTS` when set, and always into the result bundle; the events the taps
/// sent are written to `YUI_EVENTS` (or a temp file) and checked.
final class ChangeAnswerTests: XCTestCase {
    static let reply = [
        "choose \"Which split today?\" Push|Pull|Legs",
        "pick \"What gear do you have?\" Dumbbells|Bench|Bands|Kettlebell",
        "ask \"Send the invite now?\" \"Yes, send\"|\"Not yet\"",
    ].joined(separator: "\\n")

    func testChangeChooseAndPick() throws {
        let shots = ProcessInfo.processInfo.environment["YUI_SHOTS"].map { URL(fileURLWithPath: $0) }
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            if let shots { try? png.write(to: shots.appending(path: "change-\(name).png")) }
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = "change-\(name)"
            a.lifetime = .keepAlways
            add(a)
        }
        let log = ProcessInfo.processInfo.environment["YUI_EVENTS"]
            ?? FileManager.default.temporaryDirectory.appending(path: "yui12-events.jsonl").path
        try? FileManager.default.removeItem(atPath: log)

        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "wizard", "-appearance", "light",
                               "-yuiThemeDemo", Self.reply, "-yuiEventLog", log]
        app.launch()

        // choose: Push, then change to Pull.
        let push = app.buttons["Push"]
        XCTAssertTrue(push.waitForExistence(timeout: 15), "the choose never arrived")
        XCTAssertTrue(app.buttons["Kettlebell"].waitForExistence(timeout: 10), "the pick never arrived")
        sleep(1)
        shot("1-before")
        push.tap()
        sleep(1)
        shot("2-chose-push")
        let pull = app.buttons["Pull"]
        XCTAssertTrue(pull.isEnabled, "choose locked after the first answer")
        pull.tap()
        sleep(1)
        shot("3-changed-to-pull")

        // pick: Bench + Bands, send, then swap Bands for Kettlebell and send again.
        app.buttons["Bench"].tap()
        app.buttons["Bands"].tap()
        app.buttons["Done"].tap()
        let sent = app.buttons["Sent"]
        XCTAssertTrue(sent.waitForExistence(timeout: 3), "the submit button did not settle on Sent")
        sleep(1)
        shot("4-picked-bench-bands")
        app.buttons["Bands"].tap()
        app.buttons["Kettlebell"].tap()
        let resend = app.buttons["Done"]
        XCTAssertTrue(resend.waitForExistence(timeout: 3) && resend.isEnabled, "no way to send the new picks")
        sleep(1)
        shot("5-picks-changed")
        resend.tap()
        XCTAssertTrue(sent.waitForExistence(timeout: 3))

        // ask: Yes, then Not yet.
        let yes = app.buttons["Yes, send"]
        if !yes.isHittable { app.swipeUp() }
        yes.tap()
        app.buttons["Not yet"].tap()
        sleep(1)
        shot("6-ask-changed")

        let events = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n").map(String.init)
        let expected = [
            #"{"choice":"Push","id":"n1","preset":"choose"}"#,
            #"{"changed":true,"choice":"Pull","id":"n1","preset":"choose"}"#,
            #"{"id":"n2","picked":["Bench","Bands"],"preset":"pick"}"#,
            #"{"changed":true,"id":"n2","picked":["Bench","Kettlebell"],"preset":"pick"}"#,
            #"{"answer":"Yes, send","id":"n3","preset":"ask"}"#,
            #"{"answer":"Not yet","changed":true,"id":"n3","preset":"ask"}"#,
        ]
        XCTAssertEqual(events, expected)
        let a = XCTAttachment(string: events.joined(separator: "\n"))
        a.name = "events.jsonl"
        a.lifetime = .keepAlways
        add(a)
    }

    /// `+lock` (here patched on in the same reply): the taps do nothing, nothing goes back.
    func testLockedChooseSendsNothing() throws {
        let log = FileManager.default.temporaryDirectory.appending(path: "yui12-lock.jsonl").path
        try? FileManager.default.removeItem(atPath: log)
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "wizard", "-appearance", "light",
                               "-yuiThemeDemo", "choose@booking \"Table for\" Two|Four|Six\\n~booking +lock",
                               "-yuiEventLog", log]
        app.launch()
        let four = app.buttons["Four"]
        XCTAssertTrue(four.waitForExistence(timeout: 15))
        sleep(1)
        XCTAssertFalse(four.isEnabled, "+lock left the choose live")
        four.tap()
        sleep(1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log), "a locked choose sent an event")
    }
}
