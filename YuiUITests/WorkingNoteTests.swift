import XCTest

/// TestFlight: after a quiz deck, "OK, show me my weight chart" sat on dots
/// with "taking a while, run hermes gateway restart". Long turns are normal:
/// the chat must say the agent is working and count the time, with no
/// restart advice, and keep doing that when the thread is reopened mid-turn.
/// Demo account, no network (`-yuiThreadRows`). Screenshots go to `YUI_SHOTS`.
final class WorkingNoteTests: XCTestCase {
    static func ts(_ ago: TimeInterval) -> String { Date.now.addingTimeInterval(-ago).formatted(.iso8601) }

    func testLongTurnShowsWorkingAndElapsed() throws {
        let shots = ProcessInfo.processInfo.environment["YUI_SHOTS"].map { URL(fileURLWithPath: $0) }
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            if let shots { try? png.write(to: shots.appending(path: "working-\(name).png")) }
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = "working-\(name)"
            a.lifetime = .keepAlways
            add(a)
        }
        let rows: [[String: Any]] = [
            ["id": "u0", "sender": "user", "kind": "text", "body": "Quiz deck", "created_at": Self.ts(400),
             "delivered_at": Self.ts(399), "handled_at": Self.ts(380)],
            ["id": "a1", "sender": "agent", "kind": "text", "body": "Quick one on Yui itself. Learn and test at once.",
             "created_at": Self.ts(381)],
            ["id": "u1", "sender": "user", "kind": "text", "body": "OK, show me my weight chart", "created_at": Self.ts(160),
             "delivered_at": Self.ts(130)],
        ]
        let rowsFile = FileManager.default.temporaryDirectory.appending(path: "yui-working-rows.json")
        try JSONSerialization.data(withJSONObject: rows).write(to: rowsFile)

        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "wizard", "-appearance", "dark",
                               "-yuiThreadRows", rowsFile.path]
        app.launch()

        XCTAssertTrue(app.staticTexts["OK, show me my weight chart"].waitForExistence(timeout: 15), "the thread never loaded")
        let note = app.descendants(matching: .any)["working"]
        XCTAssertTrue(note.waitForExistence(timeout: 5), "reopened mid-turn: no working note, the agent looks idle")
        let first = note.label
        XCTAssertTrue(first.contains("is working · 2m "), "the note does not say it is working and for how long: \(first)")
        XCTAssertTrue(first.contains("Long jobs are fine"), "a long turn does not say it's fine to leave: \(first)")
        sleep(3)
        shot("1-long-turn")
        XCTAssertNotEqual(note.label, first, "the elapsed time does not count up")
        let restart = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'gateway restart'"))
        XCTAssertEqual(restart.count, 0, "an online agent's long turn still tells you to restart the gateway")
    }
}
