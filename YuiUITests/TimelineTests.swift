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

    private func launch(_ tag: String, appearance: String) {
        self.tag = tag
        log = FileManager.default.temporaryDirectory.appending(path: "yui65-\(tag).jsonl").path
        try? FileManager.default.removeItem(atPath: log)
        app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "wizard", "-appearance", appearance,
                               "-yuiThemeDemo", Self.warRoom.joined(separator: "\\n"), "-yuiEventLog", log]
        app.launch()
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
}
