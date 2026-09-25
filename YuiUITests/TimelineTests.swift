import XCTest

/// The timeline preset (YUI-65): done rows, the now marker, the running row,
/// the queue; older done rows fold behind "N earlier"; a row with a link
/// opens Safari and sends nothing. Streams the war room onto screen 2, the
/// way the yui agent draws it. Screenshots go to `YUI_SHOTS` when set.
final class TimelineTests: XCTestCase {
    private var app: XCUIApplication!
    private var log = ""
    private var tag = ""

    static let warRoom = [
        ">2",
        #"timeline "War room" fold=3"#,
        #"done "Three screens per agent" at="Sep 24" tag=YUI-31"#,
        #"done "Saved screens, the shelf" at="Sep 24" tag=YUI-32"#,
        #"done "Full-screen flows fold back into chat" at="Sep 24" tag=YUI-51"#,
        #"done "No dead buttons" at="Sep 24" tag=YUI-53"#,
        #"done "Test builds by link" at="Sep 24" tag=YUI-55"#,
        #"done "Links open Safari" at="Sep 25" tag=YUI-67 https://www.yuigui.com/progress"#,
        #"now "The war room timeline" tag=YUI-65 sub="spec, parsers, web done; native view next""#,
        #"next "Drag to reorder the queue" tag=YUI-66"#,
        #"next "War room panels" tag=YUI-73 sub="needs you, running, builds, feedback""#,
        #"next "Reply to a message" tag=YUI-68"#,
        "end",
        #"card "The board" sub="yuigui.com" cta="Open the board" url=https://www.yuigui.com/board"#,
    ]

    /// The war room as the generator draws it for YUI-66: the queue can be reordered,
    /// and the order goes to the yui board. YUI-73 names its card by task id.
    static let reorderRoom = [
        ">2",
        #"timeline "War room" fold=2 +reorder board=yui"#,
        #"done "Links open Safari" at="Sep 25" tag=YUI-67 https://www.yuigui.com/progress"#,
        #"done "The war room timeline" at="Sep 25" tag=YUI-65"#,
        #"now "Drag to reorder the queue" tag=YUI-66 sub="running 40m""#,
        #"next "War room panels" tag=YUI-73 key=t_61ac254a sub="needs you, running, builds, feedback""#,
        #"next "Reply to a message" tag=YUI-68"#,
        #"next "Agent controls" tag=YUI-70"#,
        "end",
    ]

    private func launch(_ tag: String, appearance: String, lines: [String] = TimelineTests.warRoom) {
        self.tag = tag
        log = FileManager.default.temporaryDirectory.appending(path: "yui65-\(tag).jsonl").path
        try? FileManager.default.removeItem(atPath: log)
        app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "wizard", "-appearance", appearance,
                               "-yuiThemeDemo", lines.joined(separator: "\\n"), "-yuiEventLog", log]
        app.launch()
    }

    private func grips() -> [String] {
        app.descendants(matching: .any).matching(identifier: "timeline-grip").allElementsBoundByIndex.map { $0.label }
    }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(tag)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "\(tag)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func events() -> String { (try? String(contentsOfFile: log, encoding: .utf8)) ?? "" }

    private func rows(_ state: String) -> Int {
        app.descendants(matching: .any).matching(identifier: "timeline-\(state)").count
    }

    func testWarRoomTimeline() throws {
        launch("timeline", appearance: "light")
        let earlier = app.buttons["timeline-earlier"]
        XCTAssertTrue(earlier.waitForExistence(timeout: 20), "the timeline never drew its fold button")
        XCTAssertTrue(app.buttons["Open the board"].waitForExistence(timeout: 10), "the reply never finished")
        sleep(1)
        XCTAssertTrue(app.descendants(matching: .any)["timeline-now"].exists, "no now marker")
        XCTAssertEqual(earlier.label, "3 earlier")
        shot("1-light")

        // Fold: 3 of the 6 done rows show; the button opens the rest in place, no event.
        let link = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Links open Safari'")).firstMatch
        XCTAssertTrue(link.exists, "the link row is not a button")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Three screens per agent'")).firstMatch.exists
                       || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Three screens per agent'")).firstMatch.exists
                       || app.otherElements.matching(NSPredicate(format: "label CONTAINS 'Three screens per agent'")).firstMatch.exists,
                       "a folded row is showing")
        earlier.tap()
        let oldest = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Three screens per agent'")).firstMatch
        XCTAssertTrue(oldest.waitForExistence(timeout: 5), "N earlier did not open the folded rows")
        XCTAssertFalse(earlier.exists, "the fold button stayed after opening")
        sleep(1)
        shot("2-unfolded")

        // A link row opens Safari and sends nothing to the chat.
        link.tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15), "the link row did not open Safari")
        XCTAssertFalse(events().contains("\"done\"") || events().contains("timeline"), "a timeline row sent an event: \(events())")
    }

    func testWarRoomTimelineDark() throws {
        launch("timeline", appearance: "dark")
        XCTAssertTrue(app.buttons["timeline-earlier"].waitForExistence(timeout: 20), "the timeline never drew")
        XCTAssertTrue(app.buttons["Open the board"].waitForExistence(timeout: 10), "the reply never finished")
        sleep(1)
        shot("3-dark")
    }

    /// YUI-66: Edit order, drag the last queued row to the top, Save sends one
    /// board order event; the running and done rows never get a handle.
    func testReorderTheQueue() throws {
        launch("reorder", appearance: "light", lines: Self.reorderRoom)
        let edit = app.buttons["timeline-edit-order"]
        XCTAssertTrue(edit.waitForExistence(timeout: 20), "no Edit order button on a +reorder timeline")
        sleep(1)
        XCTAssertTrue(grips().isEmpty, "handles showed before Edit order")
        edit.tap()
        let grip = app.descendants(matching: .any).matching(identifier: "timeline-grip")
        XCTAssertTrue(grip.firstMatch.waitForExistence(timeout: 5), "Edit order drew no handles")
        XCTAssertEqual(grips(), ["Reorder YUI-73", "Reorder YUI-68", "Reorder YUI-70"], "only queued rows get a handle")
        XCTAssertFalse(app.buttons["timeline-save-order"].isEnabled, "Save is live before anything moved")
        shot("1-edit")

        // A real drag: YUI-70's handle up past YUI-68 and YUI-73.
        let from = grip.element(boundBy: 2).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = grip.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.6))
        from.press(forDuration: 0.3, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(1)
        XCTAssertEqual(grips(), ["Reorder YUI-70", "Reorder YUI-73", "Reorder YUI-68"], "the drag did not move the row")
        shot("2-dragged")
        XCTAssertTrue(events().isEmpty, "a drag sent an event before Save: \(events())")

        app.buttons["timeline-save-order"].tap()
        sleep(1)
        let ev = events()
        XCTAssertTrue(ev.contains(#""order":["YUI-70","t_61ac254a","YUI-68"]"#), "wrong order event: \(ev)")
        XCTAssertTrue(ev.contains(#""board":"yui""#), "the event lost its board: \(ev)")
        XCTAssertTrue(ev.contains(#""preset":"timeline""#))
        XCTAssertEqual(ev.split(separator: "\n").count, 1, "Save sent more than one event")
        XCTAssertTrue(grips().isEmpty, "handles stayed after Save")
        XCTAssertTrue(edit.exists, "Edit order did not come back")
        shot("3-saved")

        // Cancel puts the rows back and sends nothing.
        edit.tap()
        XCTAssertTrue(grip.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(grips(), ["Reorder YUI-70", "Reorder YUI-73", "Reorder YUI-68"], "edit did not start from the saved order")
        let a = grip.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let b = grip.element(boundBy: 2).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.2))
        a.press(forDuration: 0.3, thenDragTo: b, withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(1)
        XCTAssertNotEqual(grips().first, "Reorder YUI-70", "the second drag did not move anything")
        app.buttons["timeline-cancel-order"].tap()
        sleep(1)
        XCTAssertTrue(grips().isEmpty)
        edit.tap()
        XCTAssertTrue(grip.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(grips(), ["Reorder YUI-70", "Reorder YUI-73", "Reorder YUI-68"], "Cancel kept the draft")
        XCTAssertEqual(events().split(separator: "\n").count, 1, "Cancel sent an event")
    }

    func testReorderDark() throws {
        launch("reorder", appearance: "dark", lines: Self.reorderRoom)
        let edit = app.buttons["timeline-edit-order"]
        XCTAssertTrue(edit.waitForExistence(timeout: 20))
        sleep(1)
        edit.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "timeline-grip").firstMatch.waitForExistence(timeout: 5))
        sleep(1)
        shot("4-edit-dark")
    }
}
