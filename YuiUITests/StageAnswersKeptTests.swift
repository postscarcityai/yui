import XCTest

/// The stage's questions screen keeps what was typed (t_7e89c333, follow-up to AnswersKeptTests): a
/// loose form on the last page is still filled after a kill and a relaunch. Demo account, no network.
/// `YUI_SHOTS=<dir>` saves screenshots.
final class StageAnswersKeptTests: XCTestCase {
    /// No apostrophes (launch arguments are plists).
    static let reply = [
        "```yui",
        "say Tell me about the business.",
        "form \"Your business\" name:text what:text",
        "```",
    ].joined(separator: "\\n")

    private var appearance = "light"

    func testStageFormKeptLight() throws { try kept("light") }
    func testStageFormKeptDark() throws { try kept("dark") }

    private func shot(_ name: String) {
        usleep(900_000)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "stagekept-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "stagekept-\(appearance)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func launch(fresh: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiAgent", "arnold", "-appearance", appearance,
                               "-yuiDemoArrive", Self.reply, "-yuiDemoArriveAfter", "1",
                               "-yuiDemoPushTap", "arnold", "-yuiDemoPushTapMessage", "arrive-1", "-yuiDemoPushTapAfter", "4"]
            + (fresh ? ["-yuiRunnerReset"] : [])
        app.launch()
        return app
    }

    private func field(_ app: XCUIApplication, _ label: String, timeout: TimeInterval = 25) -> XCUIElement? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let q = app.textFields.matching(NSPredicate(format: "identifier == %@ OR label == %@ OR placeholderValue == %@", label, label, label))
            let on = q.allElementsBoundByIndex.filter { $0.exists }
            // The questions come on one by one: let them settle before a tap.
            if !on.isEmpty { sleep(2); return q.firstMatch }
            usleep(300_000)
        }
        shot("missing-\(label)")
        return nil
    }

    /// A tap that has not raised the keyboard yet is tapped again.
    private func type(_ app: XCUIApplication, _ f: XCUIElement, _ words: String) {
        for _ in 0..<4 {
            f.tap()
            if app.keyboards.firstMatch.waitForExistence(timeout: 2) { break }
        }
        f.typeText(words)
    }

    /// The relaunch plays the turn from its first page: Next until the questions are up.
    private func toQuestions(_ app: XCUIApplication) {
        let end = Date().addingTimeInterval(40)
        while Date() < end, !app.buttons["stage-send"].exists {
            let next = app.buttons["stage-next"]
            if next.exists, next.isHittable { next.tap() }
            sleep(2)
        }
    }

    private func text(_ f: XCUIElement) -> String { (f.value as? String) ?? "" }

    /// The value any field with this label holds (the stage can draw a page twice).
    private func filled(_ app: XCUIApplication, _ label: String, is want: String, timeout: TimeInterval = 10) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let q = app.textFields.matching(NSPredicate(format: "identifier == %@ OR label == %@ OR placeholderValue == %@", label, label, label))
            if q.allElementsBoundByIndex.contains(where: { $0.exists && text($0) == want }) { return true }
            usleep(300_000)
        }
        return false
    }

    private func kept(_ look: String) throws {
        appearance = look
        var app = launch(fresh: true)
        let name = try XCTUnwrap(field(app, "Name"), "the stage questions never came")
        type(app, name, "Basil Bakery")
        let what = try XCTUnwrap(field(app, "What"))
        type(app, what, "Bread and cake")
        shot("1-before-kill")

        app.terminate()
        app = launch(fresh: false)
        toQuestions(app)
        _ = try XCTUnwrap(field(app, "Name"), "no questions after the relaunch")
        XCTAssertTrue(filled(app, "Name", is: "Basil Bakery"), "the relaunch lost the name")
        XCTAssertTrue(filled(app, "What", is: "Bread and cake"), "the relaunch lost the other field")
        shot("2-after-relaunch")
        // The kept answer counts: Send is lit without touching a field.
        let send = app.buttons.matching(NSPredicate(format: "identifier == 'stage-send' OR label == 'Send'")).firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertTrue(send.isEnabled, "Send stayed dark over a kept answer")
    }
}
