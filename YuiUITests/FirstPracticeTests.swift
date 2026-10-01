import XCTest

/// A first plan in every agent, Gouda third (YUI-222, PROP-4). A new person opens Gouda: his hello
/// plays, the four questions come last (instrument, level, minutes a day, what to play), Not sure
/// and Skip beside each, one Send. The runtime answers with the plan and draws Practice again from
/// it: today's session on a card and a timer at the bottom to start it.
/// The reply is runtime/src/music.ts's (applyPracticeFirst + practiceRedraw), verbatim, for
/// Guitar, Brand new, 20 minutes, Chords and Songs on Monday 2026-09-28 (music.test.ts "the plan
/// reply redraws Practice" holds the same shape). Demo account, no network.
/// `YUI_SHOTS=<dir>` saves screenshots.
final class FirstPracticeTests: XCTestCase {
    static let built = #"""
Your practice plan is set: 20 minutes a day on guitar, beginner level. Open Practice to see today. Tap Start on the timer when you're ready.
```yui
>5 clear
>5
stat@streak "0 days" "Streak" sub="Practice today and this starts."
stat@week-min "0 min" "This week" sub="The click logs itself after 10 seconds"
chart@practice-chart bar "Minutes a day" x=Mon|Tue|Wed|Thu|Fri|Sat|Sun y=0|0|0|0|0|0|0 unit=min
card@next-up "Today: Chords" "20 minutes. 4 min, fret each string slowly, one finger a fret, up and down. 8 min, switch between two chords, one a beat, with the click at 60. 5 min, learn the first verse of an easy song on the Chords page, half speed. 3 min, play something you like, then note what felt hard." cta="Log practice"
list@recent title="Lately" "Nothing logged yet"
timer@session 20m "Today's practice" +inline
save practice
```
"""#

    func testLight() throws { try run("light") }
    func testDark() throws { try run("dark") }

    private var appearance = "light"
    private let tmp = FileManager.default.temporaryDirectory

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "firstpractice-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "firstpractice-\(appearance)-\(name)"
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
        let log = tmp.appending(path: "yui-firstpractice-events-\(look).jsonl").path
        try? FileManager.default.removeItem(atPath: log)
        let replies = tmp.appending(path: "yui-firstpractice-replies.json")
        try JSONSerialization.data(withJSONObject: [Self.built]).write(to: replies)
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoFirstLaunch", "-yuiStageFirst", "YES", "-yuiAgent", "gouda", "-appearance", look,
                               "-yuiDemoReplyFile", replies.path, "-yuiDemoReplyTaps", "-yuiDemoReplyAfter", "0.6", "-yuiEventLog", log]
        app.launch()

        // 1. The first open plays his hello, not a blank screen, and the questions come after it.
        XCTAssertTrue(text(app, "Gouda here.", timeout: 20), "Gouda's hello did not play")
        XCTAssertTrue(text(app, "Four taps", timeout: 3), "the hello does not promise the four taps")
        sleep(1)
        shot("1-hello")
        for _ in 0..<4 where !text(app, "What do you play?", timeout: 1) {
            if app.buttons["stage-next"].exists { app.buttons["stage-next"].tap() }
        }
        XCTAssertTrue(text(app, "What do you play?", timeout: 8), "the intake's questions never came")

        // 2. One screen of questions, one Send. Not sure and Skip sit beside the real answers; Send waits for an answer.
        let send = app.buttons["stage-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "no one Send under the questions")
        XCTAssertEqual(send.label, "Build my practice")
        XCTAssertFalse(send.isEnabled, "Send before any answer")
        for a in ["Guitar", "Not sure", "Skip"] {
            XCTAssertTrue(b(app, a).waitForExistence(timeout: 3), "no \(a)")
        }
        shot("2-first-question")
        for a in ["Guitar", "Brand new", "20", "Chords", "Songs"] {
            let o = b(app, a)
            XCTAssertTrue(o.waitForExistence(timeout: 3), "no \(a)")
            if !o.isHittable { app.swipeUp() }
            b(app, a).tap()
            if a == "20" { shot("3-minutes") }
        }
        if !send.isHittable { app.swipeUp() }
        XCTAssertTrue(send.isEnabled, "Send still off with every question answered")
        shot("4-send")
        send.tap()

        // 3. Gouda answers with the plan, and it is what the answers asked for.
        XCTAssertTrue(text(app, "Your practice plan is set: 20 minutes", timeout: 20), "the plan was never built")
        sleep(1)
        let events = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        let sent = events.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }.compactMap { $0["plan"] as? [String: Any] }.last
        let p = try XCTUnwrap(sent, "no {plan} event: \(events)")
        XCTAssertEqual(p["instrument"] as? String, "Guitar")
        XCTAssertEqual(p["level"] as? String, "Brand new")
        XCTAssertEqual(p["minutes"] as? String, "20")
        XCTAssertEqual(p["want"] as? [String], ["Chords", "Songs"])

        // 4. Practice shows today's session and ends on a timer to start it.
        if app.buttons["Close full screen"].exists { app.buttons["Close full screen"].tap() }
        app.goToScreen(5)
        let page = app.descendants(matching: .any)["stage-screen-5"]
        XCTAssertTrue(page.waitForExistence(timeout: 5), "no Practice page")
        XCTAssertTrue(text(app, "Today: Chords", timeout: 5), "today's practice is not on the page")
        XCTAssertTrue(text(app, "switch between two chords", timeout: 3), "the session's steps are not on the card")
        sleep(1)
        shot("5-practice")
        XCTAssertTrue(text(app, "Today's practice", timeout: 5), "no timer to start the session")
        let timer = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Today's practice")).firstMatch
        for _ in 0..<6 where !timer.isHittable { app.swipeUp() }
        sleep(1)
        shot("6-timer")
    }

    override func setUp() async throws { continueAfterFailure = false }
}
