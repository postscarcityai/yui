import XCTest

/// A first plan in every agent, Penny fourth (YUI-223, PROP-4). A new person opens Penny: her hello
/// plays, the three questions come last (busy days, when you plan, how you want reminders), Not sure
/// and Skip beside each, one Send. The runtime answers with the routine, a card to add the first
/// must-do, and draws Today and This week again from it.
/// The reply is runtime/src/planner.ts's (applyFirst + firstLine + FIRST_START + screenLines),
/// verbatim, for Wed and Fri busy, Sunday night, 10 minutes before on Monday 2026-09-28
/// (planner.test.ts "the first Send answers with the routine" holds the same shape). Demo account, no network.
/// `YUI_SHOTS=<dir>` saves screenshots.
final class FirstWeekTests: XCTestCase {
    static let built = #"""
Your routine is set. Planning is Sunday at 7:00 pm. Wed and Fri stay light. Reminders go 10 minutes before.
```yui
card@first-start "Start this week" "Add your first must-do. It lands on Today and your week." cta="Add a to-do"
~next-task "Pick your one must-do for today" "The last one today." sub="Up next" cta="Done"
~today title=Today "Pick your one must-do for today" +check
~wrap "Evening review" "Two minutes at the end of the day: done, tomorrow or drop." cta="Wrap up the day"
>3 clear
>3
timeline@week "This week" mark=Today fold=12 +reorder
next@wk-routine-today "Pick your one must-do for today" at="Today" key=routine-today
next@wk-routine-plan-week "Plan your week" at="Sun" sub="7:00 pm" key=routine-plan-week
card@week-move "Move a task" "Drag with Edit order, or pick a task and a day." cta="Move a task"
card@week-plan "Plan again" "More on your plate? Talk it out and I'll fit it in." cta="Plan my week"
save this week
```
"""#

    func testLight() throws { try run("light") }
    func testDark() throws { try run("dark") }

    private var appearance = "light"
    private let tmp = FileManager.default.temporaryDirectory

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "firstweek-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "firstweek-\(appearance)-\(name)"
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
        let log = tmp.appending(path: "yui-firstweek-events-\(look).jsonl").path
        try? FileManager.default.removeItem(atPath: log)
        let replies = tmp.appending(path: "yui-firstweek-replies.json")
        try JSONSerialization.data(withJSONObject: [Self.built]).write(to: replies)
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoFirstLaunch", "-yuiStageFirst", "YES", "-yuiAgent", "penny", "-appearance", look,
                               "-yuiDemoReplyFile", replies.path, "-yuiDemoReplyTaps", "-yuiDemoReplyAfter", "0.6", "-yuiEventLog", log]
        app.launch()

        // 1. The first open plays her hello, not a blank screen, and the questions come after it.
        XCTAssertTrue(text(app, "Penny here.", timeout: 20), "Penny's hello did not play")
        XCTAssertTrue(text(app, "Three taps", timeout: 3), "the hello does not promise the three taps")
        sleep(1)
        shot("1-hello")
        for _ in 0..<4 where !text(app, "Which days are packed?", timeout: 1) {
            if app.buttons["stage-next"].exists { app.buttons["stage-next"].tap() }
        }
        XCTAssertTrue(text(app, "Which days are packed?", timeout: 8), "the intake's questions never came")

        // 2. One screen of questions, one Send. Not sure and Skip sit beside the real answers; Send waits for an answer.
        let send = app.buttons["stage-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "no one Send under the questions")
        XCTAssertEqual(send.label, "Set my routine")
        XCTAssertFalse(send.isEnabled, "Send before any answer")
        for a in ["Wed", "Not sure", "Skip"] {
            XCTAssertTrue(b(app, a).waitForExistence(timeout: 3), "no \(a)")
        }
        shot("2-first-question")
        for a in ["Wed", "Fri", "Sunday night", "10 minutes before"] {
            let o = b(app, a)
            XCTAssertTrue(o.waitForExistence(timeout: 3), "no \(a)")
            if !o.isHittable { app.swipeUp() }
            b(app, a).tap()
            if a == "Sunday night" { shot("3-when") }
        }
        if !send.isHittable { app.swipeUp() }
        XCTAssertTrue(send.isEnabled, "Send still off with every question answered")
        shot("4-send")
        send.tap()

        // 3. Penny answers with the routine, and it is what the answers asked for.
        XCTAssertTrue(text(app, "Your routine is set. Planning is Sunday at 7:00 pm", timeout: 20), "the routine was never built")
        sleep(1)
        let events = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        let sent = events.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }.compactMap { $0["plan"] as? [String: Any] }.last
        let p = try XCTUnwrap(sent, "no {plan} event: \(events)")
        XCTAssertEqual(p["busy"] as? [String], ["Wed", "Fri"])
        XCTAssertEqual(p["plan"] as? String, "Sunday night")
        XCTAssertEqual(p["remind"] as? String, "10 minutes before")

        // 4. The reply ends on a card to tap, and This week shows the planning slot.
        XCTAssertTrue(text(app, "Start this week", timeout: 5), "no card to start the week")
        XCTAssertTrue(b(app, "Add a to-do").waitForExistence(timeout: 3), "the card has nothing to tap")
        sleep(1)
        shot("5-routine")
        if app.buttons["Close full screen"].exists { app.buttons["Close full screen"].tap() }
        app.goToScreen(3)
        let page = app.descendants(matching: .any)["stage-screen-3"]
        XCTAssertTrue(page.waitForExistence(timeout: 5), "no This week page")
        XCTAssertTrue(text(app, "Plan your week", timeout: 5), "the planning slot is not on This week")
        sleep(1)
        shot("6-week")
        app.goToScreen(2)
        XCTAssertTrue(text(app, "Pick your one must-do for today", timeout: 5), "today's list has nothing on it")
        sleep(1)
        shot("7-today")
    }

    override func setUp() async throws { continueAfterFailure = false }
}
