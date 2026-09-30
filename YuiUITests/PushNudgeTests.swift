import XCTest

/// The notifications ask (YUI-230): after Build my week one plain line, Yes raises the system prompt, Allow registers.
/// Needs a fresh sim (permission not determined). Demo account, no network. `YUI_SHOTS=<dir>` saves screenshots.
final class PushNudgeTests: XCTestCase {
    func testLight() throws { try run("light") }
    func testDark() throws { try run("dark") }

    private var appearance = "light"
    private let tmp = FileManager.default.temporaryDirectory

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "pushnudge-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "pushnudge-\(appearance)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func b(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let all = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", id, id))
        return all.allElementsBoundByIndex.first { $0.isHittable } ?? all.firstMatch
    }

    private func text(_ app: XCUIApplication, _ label: String, timeout: TimeInterval = 5) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch.waitForExistence(timeout: timeout)
    }

    private func run(_ look: String) throws {
        appearance = look
        let log = tmp.appending(path: "yui-firstplan-events-\(look).jsonl").path
        try? FileManager.default.removeItem(atPath: log)
        let replies = tmp.appending(path: "yui-firstplan-replies.json")
        try JSONSerialization.data(withJSONObject: [FirstPlanTests.built]).write(to: replies)
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoFirstLaunch", "-yuiStageFirst", "YES", "-yuiAgent", "arnold", "-appearance", look,
                               "-yuiDemoReplyFile", replies.path, "-yuiDemoReplyTaps", "-yuiDemoReplyAfter", "0.6", "-yuiEventLog", log]
        app.launch()

        // 1. The first open plays his hello, not a blank screen, and the questions come after it.
        XCTAssertTrue(text(app, "Arnold here.", timeout: 20), "Arnold's hello did not play")
        XCTAssertTrue(text(app, "Five taps", timeout: 3), "the hello does not promise the five taps")
        sleep(1)
        shot("1-hello")
        for _ in 0..<4 where !text(app, "What are we training for?", timeout: 1) {
            if app.buttons["stage-next"].exists { app.buttons["stage-next"].tap() }
        }
        XCTAssertTrue(text(app, "What are we training for?", timeout: 8), "the intake's questions never came")

        // 2. One screen of questions, one Send. Not sure sits beside the real answers; Send waits for an answer.
        let send = app.buttons["stage-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "no one Send under the questions")
        XCTAssertEqual(send.label, "Build my week")
        XCTAssertFalse(send.isEnabled, "Send before any answer")
        for a in ["Lift heavy", "Not sure"] {
            XCTAssertTrue(b(app, a).waitForExistence(timeout: 3), "no \(a)")
        }
        for a in ["Lift heavy", "3", "45 min", "Dumbbells", "Some experience"] {
            let o = b(app, a)
            XCTAssertTrue(o.waitForExistence(timeout: 3), "no \(a)")
            if !o.isHittable { app.swipeUp() }
            b(app, a).tap()
            if a == "Dumbbells" { shot("2-questions") }
        }
        if !send.isHittable { app.swipeUp() }
        XCTAssertTrue(send.isEnabled, "Send still off with every question answered")
        shot("3-send")

        // Build my week: the line shows, once. Not before.
        XCTAssertFalse(text(app, "Want a nudge", timeout: 1), "the ask came before the plan was built")
        send.tap()
        sleep(3)
        shot("3b-after-send")
        XCTAssertTrue(text(app, "Want a nudge when Arnold checks in?", timeout: 10), "no notifications line after Build my week")
        shot("4-nudge")
        XCTAssertTrue(app.buttons["Not now"].exists, "no Not now")
        b(app, "Yes").tap()
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "Yes did not raise the system prompt")
        shot("5-system-prompt")
        alert.buttons["Allow"].tap()
        XCTAssertFalse(text(app, "Want a nudge", timeout: 2), "the line stayed after Yes")
        shot("6-allowed")
    }

    override func setUp() async throws { continueAfterFailure = false }
}
