import XCTest

/// A first plan in every agent, Quill fifth (YUI-224, PROP-4). A new person opens Quill: his hello
/// plays, the three questions come last (what you are learning, minutes a day, how you like to be
/// quizzed), Not sure and Skip beside each, one Send. The runtime answers with the study plan, a card
/// to start today's lesson, and today's lesson on What you're studying.
/// The reply is runtime/src/study.ts's (applyFirst + firstLine + FIRST_START + screenLines), verbatim,
/// for A language, 20 minutes, flash cards on Monday 2026-09-28 (study.test.ts "the first Send answers
/// with the plan" holds the same shape). Demo account, no network. `YUI_SHOTS=<dir>` saves screenshots.
final class FirstStudyTests: XCTestCase {
    static let built = #"""
Your plan is set. A language, 20 minutes a day, quizzed with flash cards. Today: the basics: a 12 minute lesson, then 16 flash cards.
```yui
card@first-start "Start today's lesson" "Today's lesson, then your quiz." cta="Start today's lesson"
~studying "Today: A language" "The basics: a 12 minute lesson, then 16 flash cards." sub="20 minutes" cta="Start today's lesson"
~decks title="Your decks" "World capitals, 8 cards"
~learn-new "Learn something new" "A topic, how long you have, what you know. A short lesson, then a quiz." cta="Learn a topic"
~walk "Stuck on a problem?" "I'll break it into steps. You answer each one before the next." cta="Walk me through it"
```
"""#

    func testLight() throws { try run("light") }
    func testDark() throws { try run("dark") }

    private var appearance = "light"
    private let tmp = FileManager.default.temporaryDirectory

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "firststudy-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "firststudy-\(appearance)-\(name)"
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
        let log = tmp.appending(path: "yui-firststudy-events-\(look).jsonl").path
        try? FileManager.default.removeItem(atPath: log)
        let replies = tmp.appending(path: "yui-firststudy-replies.json")
        try JSONSerialization.data(withJSONObject: [Self.built]).write(to: replies)
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoFirstLaunch", "-yuiStageFirst", "YES", "-yuiAgent", "quill", "-appearance", look,
                               "-yuiDemoReplyFile", replies.path, "-yuiDemoReplyTaps", "-yuiDemoReplyAfter", "0.6", "-yuiEventLog", log]
        app.launch()

        // 1. The first open plays his hello, not a blank screen, and the questions come after it.
        XCTAssertTrue(text(app, "Quill here.", timeout: 20), "Quill's hello did not play")
        XCTAssertTrue(text(app, "Three taps", timeout: 3), "the hello does not promise the three taps")
        sleep(1)
        shot("1-hello")
        for _ in 0..<4 where !text(app, "What are you learning?", timeout: 1) {
            if app.buttons["stage-next"].exists { app.buttons["stage-next"].tap() }
        }
        XCTAssertTrue(text(app, "What are you learning?", timeout: 8), "the intake's questions never came")

        // 2. One screen of questions, one Send. Not sure and Skip sit beside the real answers; Send waits for an answer.
        let send = app.buttons["stage-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "no one Send under the questions")
        XCTAssertEqual(send.label, "Build my plan")
        XCTAssertFalse(send.isEnabled, "Send before any answer")
        for a in ["A language", "Not sure", "Skip"] {
            XCTAssertTrue(b(app, a).waitForExistence(timeout: 3), "no \(a)")
        }
        shot("2-first-question")
        for a in ["A language", "20 minutes", "Flash cards"] {
            let o = b(app, a)
            XCTAssertTrue(o.waitForExistence(timeout: 3), "no \(a)")
            if !o.isHittable { app.swipeUp() }
            b(app, a).tap()
            if a == "20 minutes" { shot("3-minutes") }
        }
        if !send.isHittable { app.swipeUp() }
        XCTAssertTrue(send.isEnabled, "Send still off with every question answered")
        shot("4-send")
        send.tap()

        // 3. Quill answers with the plan, and it is what the answers asked for.
        XCTAssertTrue(text(app, "Your plan is set. A language, 20 minutes a day", timeout: 20), "the plan was never built")
        sleep(1)
        let events = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        let sent = events.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }.compactMap { $0["plan"] as? [String: Any] }.last
        let p = try XCTUnwrap(sent, "no {plan} event: \(events)")
        XCTAssertEqual(p["topic"] as? String, "A language")
        XCTAssertEqual(p["minutes"] as? String, "20 minutes")
        XCTAssertEqual(p["quiz"] as? String, "Flash cards")

        // 4. The reply ends on a card to tap, and What you're studying shows today's lesson.
        XCTAssertTrue(text(app, "Start today's lesson", timeout: 5), "no card to start today's lesson")
        XCTAssertTrue(b(app, "Start today's lesson").waitForExistence(timeout: 3), "the card has nothing to tap")
        sleep(1)
        shot("5-plan")
        if app.buttons["Close full screen"].exists { app.buttons["Close full screen"].tap() }
        app.goToScreen(2)
        let page = app.descendants(matching: .any)["stage-screen-2"]
        XCTAssertTrue(page.waitForExistence(timeout: 5), "no What you're studying page")
        XCTAssertTrue(text(app, "Today: A language", timeout: 5), "today's lesson is not on What you're studying")
        sleep(1)
        shot("6-studying")
    }

    override func setUp() async throws { continueAfterFailure = false }
}
