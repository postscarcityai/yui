import XCTest

/// A reopened thread shows its answers (TestFlight: chosen, picked and slid
/// components came back blank). The app loads a thread's rows the way it does
/// on open (`-yuiThreadRows`): an agent reply, then the person's event rows.
/// Components must come back answered, and a new tap must go out as a change.
/// Demo account, no network. Screenshots go to `YUI_SHOTS` when set.
final class ReopenAnswersTests: XCTestCase {
    static let reply = """
    choose "Which split today?" Push|Pull|Legs
    pick "What gear do you have?" Dumbbells|Bench|Bands|Kettlebell
    slide "Energy" 1-5
    ask "Send the invite now?" "Yes, send"|"Not yet"
    """

    static func event(_ id: String, _ yl: String, _ preset: String, _ value: [String: Any], _ echo: String) -> [String: Any] {
        ["id": id, "sender": "user", "kind": "event", "body": "[yui] \(yl) \(preset)", "created_at": "2026-09-24T10:00:0\(id.last!)+00:00",
         "meta": ["id": yl, "preset": preset, "value": value, "echo": echo]]
    }

    static var rows: [[String: Any]] { [
        ["id": "r1", "sender": "agent", "kind": "text", "body": "```yui\n\(reply)\n```", "created_at": "2026-09-24T10:00:00+00:00"],
        event("e1", "n1", "choose", ["choice": "Push"], "Push"),
        event("e2", "n1", "choose", ["choice": "Pull", "changed": true], "Pull"),
        event("e3", "n2", "pick", ["picked": ["Bench", "Bands"]], "Bench, Bands"),
        event("e4", "n3", "slide", ["value": 4], "4"),
        event("e5", "n4", "ask", ["answer": "Not yet"], "Not yet"),
    ] }

    func testReopenedThreadShowsAnswers() throws {
        let shots = ProcessInfo.processInfo.environment["YUI_SHOTS"].map { URL(fileURLWithPath: $0) }
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            if let shots { try? png.write(to: shots.appending(path: "reopen-\(name).png")) }
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = "reopen-\(name)"
            a.lifetime = .keepAlways
            add(a)
        }
        let tmp = FileManager.default.temporaryDirectory
        let rowsFile = tmp.appending(path: "yui-reopen-rows.json")
        try JSONSerialization.data(withJSONObject: Self.rows).write(to: rowsFile)
        let log = tmp.appending(path: "yui-reopen-events.jsonl").path
        try? FileManager.default.removeItem(atPath: log)

        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "wizard", "-appearance", "light",
                               "-yuiThreadRows", rowsFile.path, "-yuiEventLog", log]
        app.launch()

        XCTAssertTrue(app.buttons["Kettlebell"].waitForExistence(timeout: 15), "the thread never loaded")
        sleep(1)
        shot("1-reopened-top")

        // pick: Bench + Bands went out, so the submit reads Sent, not Done.
        XCTAssertTrue(app.buttons["Sent"].exists, "pick came back blank: the submit reads Done, not Sent")
        XCTAssertFalse(app.buttons["Done"].exists, "pick came back blank")

        // slide: released at 4 of 1-5, not the blank midpoint 3.
        let slider = app.sliders.firstMatch
        XCTAssertTrue(slider.exists)
        XCTAssertEqual(slider.value as? String, "4","the slider came back at its default, not where it was released")

        // The chat sits at its newest row: scroll back up to the choose (swipe in the
        // avatar gutter so the drag never lands on the slider).
        let gutter = app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.3))
        gutter.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.85)))
        sleep(1)
        shot("2-reopened-choose-pick")

        // choose and ask: a new tap is a change of answer, so it carries `changed`.
        app.buttons["Legs"].tap()
        app.buttons["Yes, send"].tap()
        sleep(1)
        let events = (try? String(contentsOfFile: log, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        let legs = events.first { $0.contains("\"choice\":\"Legs\"") }
        let yes = events.first { $0.contains("\"answer\":\"Yes, send\"") }
        XCTAssertNotNil(legs, "tapping Legs sent nothing: \(events)")
        XCTAssertNotNil(yes, "tapping Yes, send sent nothing: \(events)")
        XCTAssertTrue(legs?.contains("\"changed\":true") == true, "choose forgot it was answered (Pull): \(legs ?? "")")
        XCTAssertTrue(yes?.contains("\"changed\":true") == true, "ask forgot it was answered (Not yet): \(yes ?? "")")
        shot("3-changed-after-reopen")
    }
}
