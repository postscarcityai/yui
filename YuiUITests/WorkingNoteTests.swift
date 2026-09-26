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
        XCTAssertTrue(first.contains(" · 2m "), "the row does not say how long it has been working: \(first)")
        XCTAssertFalse(first.contains("On its way"), "picked up, but the row still says it is on its way: \(first)")
        // One row: no separate dots bubble.
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'is typing'")).count, 0,
                       "the old dots bubble is still there next to the working row")
        XCTAssertTrue(first.contains("Long jobs are fine"), "a long turn does not say it's fine to leave: \(first)")
        sleep(3)
        shot("1-long-turn")
        XCTAssertNotEqual(note.label, first, "the elapsed time does not count up")
        let restart = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'gateway restart'"))
        XCTAssertEqual(restart.count, 0, "an online agent's long turn still tells you to restart the gateway")
    }

    /// YUI-63: sending shows one row (no dots bubble next to a status line):
    /// "On its way" until the host picks it up, then a working word that
    /// changes every few seconds with the time, gone when the answer lands.
    func testOneWorkingRowFromSendToReply() throws {
        for appearance in ["light", "dark"] {
            let shots = ProcessInfo.processInfo.environment["YUI_SHOTS"].map { URL(fileURLWithPath: $0) }
            func shot(_ name: String) {
                let png = XCUIScreen.main.screenshot().pngRepresentation
                if let shots { try? png.write(to: shots.appending(path: "working-row-\(appearance)-\(name).png")) }
                let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                a.name = "working-row-\(appearance)-\(name)"
                a.lifetime = .keepAlways
                add(a)
            }
            let app = XCUIApplication()
            app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "wizard", "-appearance", appearance,
                                   "-yuiDemoReply", "say Here you go.", "-yuiDemoPickupAfter", "3", "-yuiDemoReplyAfter", "14"]
            app.launch()
            let input = app.descendants(matching: .any)["composer"].firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 20), "no composer")
            input.tap()
            input.typeText("What's queued up on the board?")
            app.buttons["Send"].tap()

            let row = app.descendants(matching: .any)["working"]
            XCTAssertTrue(row.waitForExistence(timeout: 3), "sending shows no working row")
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "working").count, 1, "more than one working row")
            XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'is typing'")).count, 0,
                           "the old dots bubble is back")
            XCTAssertTrue(row.label.contains("On its way · "), "before pickup it should be on its way: \(row.label)")
            shot("1-on-its-way")

            let picked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Pondering · '"), object: row)
            XCTAssertEqual(XCTWaiter.wait(for: [picked], timeout: 5), .completed, "picked up, no working word: \(row.label)")
            shot("2-pondering")
            let next = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "NOT (label CONTAINS 'Pondering') AND NOT (label CONTAINS 'On its way')"), object: row)
            XCTAssertEqual(XCTWaiter.wait(for: [next], timeout: 6), .completed, "the working word does not rotate: \(row.label)")
            shot("3-next-word")

            XCTAssertTrue(app.staticTexts["Here you go."].waitForExistence(timeout: 15), "the answer never landed")
            XCTAssertTrue(row.waitForNonExistence(timeout: 3), "the working row stayed after the answer")
            shot("4-answered")
            app.terminate()
        }
    }

    /// YUI-63 step 2: the agent says what it is doing. The row steps through
    /// three `doing` lines (its words in place of the working word, a bar for
    /// the step, the seconds still counting), then the reply clears it.
    func testDoingStepsThenTheReply() throws {
        for appearance in ["light", "dark"] {
            let shots = ProcessInfo.processInfo.environment["YUI_SHOTS"].map { URL(fileURLWithPath: $0) }
            func shot(_ name: String) {
                let png = XCUIScreen.main.screenshot().pngRepresentation
                if let shots { try? png.write(to: shots.appending(path: "doing-\(appearance)-\(name).png")) }
                let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                a.name = "doing-\(appearance)-\(name)"
                a.lifetime = .keepAlways
                add(a)
            }
            let app = XCUIApplication()
            app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "wizard", "-appearance", appearance,
                                   "-yuiDemoReply", "say Free at 3. Want it?", "-yuiDemoPickupAfter", "1",
                                   "-yuiDemoReplyAfter", "17",
                                   "-yuiDemoDoing",
                                   "Reading your calendar 1/3|Checking the weather 2/3|Drafting the plan 3/3"]
            app.launch()
            let input = app.descendants(matching: .any)["composer"].firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 20), "no composer")
            input.tap()
            input.typeText("Plan my afternoon")
            app.buttons["Send"].tap()

            let row = app.descendants(matching: .any)["working"]
            XCTAssertTrue(row.waitForExistence(timeout: 3), "sending shows no working row")
            var seconds: [String] = []
            for (i, words) in ["Reading your calendar", "Checking the weather", "Drafting the plan"].enumerated() {
                let want = "Wizard: \(words), step \(i + 1) of 3 · "
                let got = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", want), object: row)
                XCTAssertEqual(XCTWaiter.wait(for: [got], timeout: 8), .completed, "no step \(i + 1): \(row.label)")
                XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "working").count, 1, "more than one working row")
                // Never a bubble: the words live only in the working row.
                XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label == %@", words)).allElementsBoundByIndex
                                .contains { $0.frame.minY > row.frame.maxY || $0.frame.maxY < row.frame.minY },
                               "\(words) shows outside the working row")
                seconds.append(String(row.label.split(separator: "·").last ?? ""))
                shot("\(i + 1)-step")
            }
            XCTAssertNotEqual(seconds.first, seconds.last, "the seconds stopped counting: \(seconds)")
            XCTAssertTrue(app.staticTexts["Free at 3. Want it?"].waitForExistence(timeout: 12), "the answer never landed")
            XCTAssertTrue(row.waitForNonExistence(timeout: 3), "the working row stayed after the answer")
            XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Drafting the plan'")).count, 0,
                           "the doing words outlived the reply")
            shot("4-answered")
            app.terminate()
        }
    }
}
