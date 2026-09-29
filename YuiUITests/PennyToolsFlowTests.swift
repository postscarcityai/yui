import XCTest

/// Penny's tools, the whole way (YUI-185): Plan my week from her home chip as one
/// full-screen plan (how it works, the brain dump by voice or typed, the questions last,
/// one Send), the week landing on This week with a reminder on the phone's clock, a
/// Today task ticked (quiet: no working row, the runtime's patches move the Today mark),
/// This week dragged into a new order, and the evening review as one plan with one Send.
/// Then the app is killed and relaunched: the pages, the tick and the saved order come
/// back, and five trips to another agent and back keep them. Chris (Sep 28): the 0.5.0
/// switch-agent crash hid behind the demo account's memory, so the order and the ticks
/// live in UserDefaults and this test only passes if they come back from there. Every
/// agent reply is runtime/src/planner.ts's, verbatim. Demo account, no network.
/// `YUI_SHOTS=<dir>` saves screenshots.
final class PennyToolsFlowTests: XCTestCase {
    /// runtime (planner.ts), verbatim: plan.
    static let plan = #"""
Let's get your week out of your head.
```yui
plan@weekplan "Plan my week" submit="Plan my week"
page "Your week, out of your head" body="Talk it out: everything on your plate, in any order. Say a day or a time when there is one. I'll sort the rest into days, never more a day than you pick, and put it on a timeline you can drag around. Nothing's on it yet."
mic@dump "Everything on your plate this week"
pick@busy "Any days already full?" "Today"|"Tuesday"|"Wednesday"|"Thursday"|"Friday"|"Saturday"|"Sunday" submit=Next
choose@pace "How many things a day?" "2 or 3"|"3 to 5"|"As many as fit"
choose@remind "Remind you of timed things?" "10 minutes before"|"At the time"|"No reminders"
```
"""#

    /// runtime (planner.ts), verbatim: planned.
    static let planned = #"""
Your week is planned: 5 things over 2 days. Drag to reorder on This week. The timed one gets a reminder. First up: pay the water bill.
```yui
~next-task "Pay the water bill" "2 more today after this." sub="Up next" cta="Done"
~today title=Today "Pay the water bill"|"Groceries"|"Pick up the dry cleaning" +check
~wrap "Evening review" "Two minutes at the end of the day: done, tomorrow or drop." cta="Wrap up the day"
>3 clear
>3
timeline@week "This week" mark=Today fold=12 +reorder
next@wk-pay-the-water-bill "Pay the water bill" at="Today" key=pay-the-water-bill
next@wk-groceries "Groceries" at="Today" key=groceries
next@wk-pick-up-the-dry-cleaning "Pick up the dry cleaning" at="Today" key=pick-up-the-dry-cleaning
next@wk-call-the-dentist "Call the dentist" at="Tomorrow" sub="9:00 am" key=call-the-dentist
next@wk-book-a-haircut "Book a haircut" at="Tomorrow" key=book-a-haircut
card@week-move "Move a task" "Drag with Edit order, or pick a task and a day." cta="Move a task"
card@week-plan "Plan again" "More on your plate? Talk it out and I'll fit it in." cta="Plan my week"
save this week
```
"""#

    /// runtime (planner.ts), verbatim: tick.
    static let tick = #"""
```yui
~next-task "Groceries" "1 more today after this." sub="Up next" cta="Done"
~today title=Today "Groceries"|"Pick up the dry cleaning" +check
~wrap "Evening review" "1 done so far. Two minutes: done, tomorrow or drop." cta="Wrap up the day"
~wk-pay-the-water-bill "Pay the water bill" at="Today" key=pay-the-water-bill kind=done
~wk-groceries "Groceries" at="Today" key=groceries kind=next
~wk-pick-up-the-dry-cleaning "Pick up the dry cleaning" at="Today" key=pick-up-the-dry-cleaning kind=next
~wk-call-the-dentist "Call the dentist" at="Tomorrow" sub="9:00 am" key=call-the-dentist kind=next
~wk-book-a-haircut "Book a haircut" at="Tomorrow" key=book-a-haircut kind=next
~week-move "Move a task" "Drag with Edit order, or pick a task and a day." cta="Move a task"
~week-plan "Plan again" "More on your plate? Talk it out and I'll fit it in." cta="Plan my week"
```
"""#

    /// runtime (planner.ts), verbatim: order.
    static let order = #"""
Moved book a haircut to today and pick up the dry cleaning to tomorrow.
```yui
~next-task "Book a haircut" "1 more today after this." sub="Up next" cta="Done"
~today title=Today "Book a haircut"|"Groceries" +check
~wrap "Evening review" "1 done so far. Two minutes: done, tomorrow or drop." cta="Wrap up the day"
~wk-pay-the-water-bill "Pay the water bill" at="Today" key=pay-the-water-bill kind=done
~wk-book-a-haircut "Book a haircut" at="Today" key=book-a-haircut kind=next
~wk-groceries "Groceries" at="Today" key=groceries kind=next
~wk-pick-up-the-dry-cleaning "Pick up the dry cleaning" at="Tomorrow" key=pick-up-the-dry-cleaning kind=next
~wk-call-the-dentist "Call the dentist" at="Tomorrow" sub="9:00 am" key=call-the-dentist kind=next
~week-move "Move a task" "Drag with Edit order, or pick a task and a day." cta="Move a task"
~week-plan "Plan again" "More on your plate? Talk it out and I'll fit it in." cta="Plan my week"
```
"""#

    /// runtime (planner.ts), verbatim: review.
    static let review = #"""
```yui
plan@review "Evening review" submit="Wrap up the day"
page "1 done today" body="Nice. 2 still open: done, tomorrow or drop each one." points="Pay the water bill"
choose@r-book-a-haircut "Book a haircut" "Done"|"Tomorrow"|"Drop"
choose@r-groceries "Groceries" "Done"|"Tomorrow"|"Drop"
choose@feel "How did today go?" "Great"|"Okay"|"Rough"
```
"""#

    /// runtime (planner.ts), verbatim: reviewed.
    static let reviewed = #"""
Day wrapped: 1 done. First up tomorrow: book a haircut.
```yui
~next-task "Book a haircut" "The last one today." sub="Up next" cta="Done"
~today title=Today "Book a haircut" +check
~wrap "Evening review" "2 done so far. Two minutes: done, tomorrow or drop." cta="Wrap up the day"
~wk-pay-the-water-bill "Pay the water bill" at="Today" key=pay-the-water-bill kind=done
~wk-groceries "Groceries" at="Today" key=groceries kind=done
~wk-book-a-haircut "Book a haircut" at="Today" key=book-a-haircut kind=next
~wk-pick-up-the-dry-cleaning "Pick up the dry cleaning" at="Tomorrow" key=pick-up-the-dry-cleaning kind=next
~wk-call-the-dentist "Call the dentist" at="Tomorrow" sub="9:00 am" key=call-the-dentist kind=next
~week-move "Move a task" "Drag with Edit order, or pick a task and a day." cta="Move a task"
~week-plan "Plan again" "More on your plate? Talk it out and I'll fit it in." cta="Plan my week"
```
"""#

    /// The planned reply's meta, as the runtime writes it.
    static var plannedMeta: [String: Any] { ["native": ["plannertool": "planned", "reminders": [
        ["key": "call-the-dentist", "text": "Call the dentist, 9:00 am", "at": "2026-09-29T08:50"]]]] }

    private var appearance = "light"
    private let tmp = FileManager.default.temporaryDirectory

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "penny-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "penny-\(appearance)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    /// The one on screen: the chat keeps its own copy under the full screen.
    private func b(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let all = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", id, id))
        return all.allElementsBoundByIndex.first { $0.isHittable } ?? all.firstMatch
    }

    private func hittable(_ app: XCUIApplication, _ id: String, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if b(app, id).exists, b(app, id).isHittable { return true }
            usleep(300_000)
        }
        return false
    }

    private func text(_ app: XCUIApplication, _ label: String, timeout: TimeInterval = 5) -> Bool {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch.waitForExistence(timeout: timeout)
    }

    /// The stage's Next, until `there`.
    private func forward(_ app: XCUIApplication, _ there: () -> Bool) {
        for _ in 0..<6 where !there() {
            let next = app.buttons["stage-next"]
            if next.exists, next.isHittable, next.isEnabled { next.tap() } else { return }
        }
    }

    /// iOS's notification prompt, if this sim has not answered it yet.
    private func allowNotifications() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 4) { allow.tap() }
    }

    private func grips(_ app: XCUIApplication) -> [String] {
        // Only the timeline being edited has handles (the chat's copy under the stage is not in Edit order).
        app.descendants(matching: .any).matching(identifier: "timeline-grip").allElementsBoundByIndex.map { $0.label }
    }

    private func write(_ name: String, _ object: Any) throws -> String {
        let url = tmp.appending(path: name)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return url.path
    }

    private func lines(_ path: String) -> [[String: Any]] {
        ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiAgent", "penny", "-appearance", appearance] + args
        app.launch()
        return app
    }

    /// The thread as the server hands it back on open: the home, then every row the flow wrote.
    /// The saved order and the tick are kept on the phone, so they can only come from UserDefaults.
    private func rows() -> [[String: Any]] {
        var n = 0
        func row(_ id: String, _ sender: String, _ body: String, kind: String = "text", meta: [String: Any]? = nil) -> [String: Any] {
            n += 1
            var r: [String: Any] = ["id": id, "sender": sender, "kind": kind, "body": body,
                                    "created_at": String(format: "2026-09-28T16:00:%02d+00:00", n)]
            if let meta { r["meta"] = meta }
            return r
        }
        func event(_ id: String, _ tap: String, _ preset: String, _ value: [String: Any], echo: String?) -> [String: Any] {
            var m: [String: Any] = ["id": tap, "preset": preset, "value": value]
            if let echo { m["echo"] = echo }
            return row(id, "user", "[yui] \(tap) \(preset)", kind: "event", meta: m)
        }
        return [
            row("home-penny", "agent", Self.homeRow, meta: ["native": "home"]),
            row("u1", "user", "Plan my week"),
            row("a1", "agent", Self.plan),
            event("e1", "weekplan", "plan", ["plan": ["dump": "Call the dentist Tuesday at 9. Groceries, pay the water bill",
                                                      "busy": ["Wednesday"], "pace": "2 or 3", "remind": "10 minutes before"]],
                  echo: "Everything on your plate this week: Call the dentist Tuesday at 9"),
            row("a2", "agent", Self.planned, meta: Self.plannedMeta),
            event("e2", "today", "list", ["item": "Pay the water bill", "checked": true], echo: nil),
            row("a3", "agent", Self.tick),
            event("e3", "week", "timeline", ["order": ["book-a-haircut", "groceries", "pick-up-the-dry-cleaning", "call-the-dentist"]],
                  echo: "New order: Book a haircut, Groceries, Pick up the dry cleaning, Call the dentist"),
            row("a4", "agent", Self.order),
            row("u2", "user", "Evening review"),
            row("a5", "agent", Self.review),
            event("e5", "review", "plan", ["plan": ["r-groceries": "Done", "feel": "Okay"]], echo: "Groceries Done"),
            row("a6", "agent", Self.reviewed),
        ]
    }

    func testLight() throws { try run("light") }
    func testDark() throws { try run("dark") }

    private func run(_ look: String) throws {
        appearance = look
        let log = tmp.appending(path: "yui-penny-events-\(look).jsonl").path
        let remind = tmp.appending(path: "yui-penny-reminders-\(look).jsonl").path
        for p in [log, remind] { try? FileManager.default.removeItem(atPath: p) }
        let planned: [String: Any] = ["body": Self.planned, "meta": Self.plannedMeta]
        let replies = try write("yui-penny-replies.json", [Self.plan, planned, Self.tick, Self.order, Self.review, Self.reviewed])
        var app = launch(["-yuiDemoHome", "-yuiDemoReplyFile", replies, "-yuiDemoReplyTaps", "-yuiDemoReplyTicks",
                          "-yuiDemoReplyAfter", "0.6", "-yuiEventLog", log, "-yuiRemindersLog", remind,
                          "-yuiTicksReset", "-yuiRemindersReset", "-yuiPTTFake", "book a haircut"])

        // Her home: four shortcuts, Plan my week the big one.
        let chip = app.buttons["home-chip-plan"]
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "no Plan my week chip on Penny's home")
        for id in ["home-chip-todo", "home-chip-next", "home-chip-review"] {
            XCTAssertTrue(app.buttons[id].exists, "no \(id) on her home")
        }
        shot("1-home")
        chip.tap()

        // One full-screen plan: how it works first, then the brain dump and the questions, one Send.
        XCTAssertTrue(text(app, "out of your head", timeout: 15), "Penny never answered")
        forward(app) { self.text(app, "Your week, out of your head", timeout: 1) }
        XCTAssertTrue(text(app, "Your week, out of your head", timeout: 5), "the plan never opened on how it works")
        shot("2-plan-open")
        forward(app) { self.hittable(app, "mic-talk-dump", timeout: 1) }
        XCTAssertTrue(hittable(app, "mic-talk-dump", timeout: 5), "no talk button on the brain dump")
        let send = app.buttons["stage-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "no one Send under the questions")
        XCTAssertEqual(send.label, "Plan my week")
        XCTAssertFalse(send.isEnabled, "Send before any answer")

        // Typed first (the mic step types too), then talked: the words join.
        let box = app.textViews["mic-text-dump"].exists ? app.textViews["mic-text-dump"] : app.textFields["mic-text-dump"]
        XCTAssertTrue(box.waitForExistence(timeout: 3), "the brain dump has no text box")
        box.tap()
        box.typeText("Call the dentist Tuesday at 9. Groceries, pay the water bill")
        XCTAssertTrue(send.isEnabled, "typed words did not count as the brain dump")
        let talk = b(app, "mic-talk-dump")
        talk.tap()
        XCTAssertTrue(app.staticTexts.matching(identifier: "mic-heard-dump").firstMatch.waitForExistence(timeout: 5)
                      || text(app, "Listening", timeout: 2), "the talk button did not listen")
        shot("3-talking")
        b(app, "mic-talk-dump").tap()
        let joined = NSPredicate { _, _ in ((box.value as? String) ?? "").contains("book a haircut") }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: joined, object: box)], timeout: 5), .completed,
                       "the talk did not land in the box: \(box.value ?? "")")
        XCTAssertTrue((box.value as? String ?? "").hasPrefix("Call the dentist"), "talking replaced the typed words")
        for a in ["Wednesday", "2 or 3", "10 minutes before"] {
            let o = b(app, a)
            XCTAssertTrue(o.waitForExistence(timeout: 3), "no \(a)")
            if !o.isHittable { app.swipeUp() }
            b(app, a).tap()
        }
        if !send.isHittable { app.swipeUp() }
        shot("4-questions")
        send.tap()

        // The week lands; the reminder goes on the phone's clock (asked for here, in context, once).
        XCTAssertTrue(text(app, "Your week is planned", timeout: 20), "the week never landed")
        allowNotifications()
        let p = try XCTUnwrap(lines(log).compactMap { $0["plan"] as? [String: Any] }.last, "no {plan} event")
        XCTAssertEqual(p["pace"] as? String, "2 or 3")
        XCTAssertEqual(p["busy"] as? [String], ["Wednesday"])
        XCTAssertEqual(p["remind"] as? String, "10 minutes before")
        let dump = p["dump"] as? String ?? ""
        XCTAssertTrue(dump.hasPrefix("Call the dentist Tuesday at 9") && dump.contains("book a haircut"), "the brain dump: \(dump)")
        let set = NSPredicate { _, _ in !self.lines(remind).isEmpty }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: set, object: nil)], timeout: 8), .completed,
                       "the reminders never reached the phone's clock")
        let r = lines(remind).last ?? [:]
        XCTAssertEqual(r["agent"] as? String, "demo-penny")
        XCTAssertEqual(r["scheduled"] as? [String], ["yui.reminder.demo-penny.call-the-dentist"], "not scheduled: \(r)")
        sleep(1)
        shot("5-planned")

        // Today: the next task big, a tick that says nothing back; the runtime's patches follow.
        if app.buttons["Close full screen"].exists { app.buttons["Close full screen"].tap() }
        app.goToScreen(2)
        let today = app.descendants(matching: .any)["stage-screen-2"]
        XCTAssertTrue(today.waitForExistence(timeout: 5), "no Today page")
        XCTAssertTrue(today.staticTexts["Pay the water bill"].waitForExistence(timeout: 5), "Today does not show the next task")
        shot("6-today")
        let water = today.buttons.matching(NSPredicate(format: "label == %@", "Pay the water bill")).allElementsBoundByIndex.first { $0.isHittable }
        try XCTUnwrap(water, "no Pay the water bill row to tick").tap()
        XCTAssertFalse(app.descendants(matching: .any)["stage-working"].waitForExistence(timeout: 1), "a tick started a turn")
        XCTAssertTrue(today.staticTexts["Groceries"].waitForExistence(timeout: 8), "the tick's patches never moved Today on")
        let tick = lines(log).last { $0["preset"] as? String == "list" }
        XCTAssertEqual(tick?["item"] as? String, "Pay the water bill")
        XCTAssertEqual(tick?["checked"] as? Bool, true)
        sleep(1)
        shot("7-ticked")

        // This week: the done task above the Today mark, then a drag to a new order.
        app.goToScreen(3)
        let week = app.descendants(matching: .any)["stage-screen-3"]
        XCTAssertTrue(week.waitForExistence(timeout: 5), "no This week page")
        let now = week.descendants(matching: .any)["timeline-now"]
        let paid = week.staticTexts["Pay the water bill"]
        XCTAssertTrue(now.waitForExistence(timeout: 5) && paid.waitForExistence(timeout: 5))
        XCTAssertLessThan(paid.frame.midY, now.frame.midY, "the done task is not above the Today mark")
        shot("8-week")
        let edit = week.buttons["timeline-edit-order"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "no Edit order on This week")
        edit.tap()
        let grip = app.descendants(matching: .any).matching(identifier: "timeline-grip")
        XCTAssertTrue(grip.firstMatch.waitForExistence(timeout: 5), "Edit order drew no handles")
        XCTAssertEqual(grips(app), ["Reorder Groceries", "Reorder Pick up the dry cleaning", "Reorder Call the dentist", "Reorder Book a haircut"])
        let last = grip.allElementsBoundByIndex
        XCTAssertEqual(last.count, 4)
        let from = last[3].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = last[0].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.6))
        from.press(forDuration: 0.3, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(1)
        XCTAssertEqual(grips(app).first, "Reorder Book a haircut", "the drag did not move the haircut up")
        shot("9-dragged")
        week.buttons["timeline-save-order"].tap()
        XCTAssertTrue(text(app, "Moved book a haircut to today", timeout: 10), "the new order was never answered")
        let order = lines(log).last { $0["preset"] as? String == "timeline" }?["order"] as? [String]
        XCTAssertEqual(order, ["book-a-haircut", "groceries", "pick-up-the-dry-cleaning", "call-the-dentist"])
        sleep(1)
        if app.buttons["Close full screen"].exists { app.buttons["Close full screen"].tap() }
        app.goToScreen(3)
        shot("10-week-saved")

        // The evening review: one plan, what got done first, then each open task, one Send.
        app.goToScreen(1)
        let review = app.buttons["home-chip-review"]
        XCTAssertTrue(review.waitForExistence(timeout: 5), "no Evening review chip")
        review.tap()
        XCTAssertTrue(text(app, "Evening review", timeout: 15), "Penny never answered the review")
        // It plays a part at a time: step back to its first page if it already moved on.
        for _ in 0..<3 where !text(app, "1 done today", timeout: 2) {
            let back = app.buttons["stage-back"]
            if back.exists, back.isHittable, back.isEnabled { back.tap() }
        }
        XCTAssertTrue(text(app, "1 done today", timeout: 5), "the review did not open on what got done")
        shot("11-review-open")
        forward(app) { self.hittable(app, "Okay", timeout: 1) }
        let wrap = app.buttons["stage-send"]
        XCTAssertTrue(wrap.waitForExistence(timeout: 5))
        XCTAssertEqual(wrap.label, "Wrap up the day")
        let dones = app.buttons.matching(NSPredicate(format: "label == %@", "Done")).allElementsBoundByIndex
            .filter { $0.isHittable }.sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertGreaterThanOrEqual(dones.count, 2, "a Done for each open task")
        dones[1].tap()
        b(app, "Okay").tap()
        if !wrap.isHittable { app.swipeUp() }
        shot("12-review-answered")
        wrap.tap()
        XCTAssertTrue(text(app, "Day wrapped", timeout: 15), "the review was never answered")
        let rv = try XCTUnwrap(lines(log).compactMap { $0["plan"] as? [String: Any] }.last)
        XCTAssertEqual(rv["r-groceries"] as? String, "Done")
        XCTAssertEqual(rv["feel"] as? String, "Okay")
        sleep(1)
        shot("13-wrapped")

        // Killed: the thread comes back from the server's rows, the tick and the order from the phone.
        app.terminate()
        let thread = try write("yui-penny-rows.json", rows())
        app = launch(["-yuiDemoHome", "-yuiThreadRows", thread, "-yuiEventLog", log, "-yuiRemindersLog", remind])
        XCTAssertTrue(app.buttons["home-chip-plan"].waitForExistence(timeout: 15), "no home after the relaunch")
        // Groceries was done in the review, so it left the queue; the rest keep the saved order.
        let keptOrder = ["Reorder Book a haircut", "Reorder Pick up the dry cleaning", "Reorder Call the dentist"]
        func checkWeek(_ when: String) {
            app.goToScreen(3)
            let w = app.descendants(matching: .any)["stage-screen-3"]
            XCTAssertTrue(w.buttons["timeline-edit-order"].waitForExistence(timeout: 8), "This week is gone \(when)")
            w.buttons["timeline-edit-order"].tap()
            XCTAssertTrue(grip.firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(grips(app), keptOrder, "the saved order was lost \(when)")
            w.buttons["timeline-cancel-order"].tap()
            app.goToScreen(2)
            let t = app.descendants(matching: .any)["stage-screen-2"]
            XCTAssertTrue(t.staticTexts["Book a haircut"].waitForExistence(timeout: 8), "Today lost the next task \(when)")
        }
        checkWeek("after the relaunch")
        shot("14-relaunched")
        XCTAssertLessThanOrEqual(lines(remind).count, 1, "an old reply undid the reminders on relaunch: \(lines(remind))")

        // Five trips to another agent and back (the 0.5.0 crash path): up, and everything kept.
        for i in 1...5 {
            if app.buttons["Close full screen"].exists { app.buttons["Close full screen"].tap() }
            XCTAssertTrue(app.pickAgent("Yui"), "could not switch to Yui (trip \(i))")
            XCTAssertTrue(app.pickAgent("Penny"), "could not switch back to Penny (trip \(i))")
            XCTAssertEqual(app.state, .runningForeground, "the app died on trip \(i)")
        }
        let who = app.talkingTo()
        XCTAssertTrue(who.contains("Penny"), "not back on Penny: \(who)")
        checkWeek("after 5 switches")
        app.goToScreen(3)
        shot("15-after-switches")
    }

    /// Penny's home row, as yui-agents writes it (runtime/profiles/penny/home.yui).
    static let homeRow = #"""
```yui
menu shortcut@review "Evening review" say="Evening review"
menu shortcut@next "What's next?" say="What's next today?"
menu shortcut@todo "Add a to-do" say="Add a to-do: "
menu shortcut@plan "Plan my week" say="Plan my week"
>2
card@next-task "Nothing on today yet" "Tell me what's on your mind and I'll sort your week into days." sub="Up next" cta="Plan my week"
list@today title=Today "Nothing on today" +check
card@wrap "Evening review" "Two minutes at the end of the day: done, tomorrow or drop." cta="Wrap up the day"
save today
>3
timeline@week "This week" mark=Today fold=12
next@wk-t1 "Tell Penny what's on your mind this week" at="Any day" key=t1
card@week-move "Move a task" "Drag with Edit order, or pick a task and a day." cta="Move a task"
card@week-plan "Plan my week" "Talk it out: everything on your plate. I'll sort it into days." cta="Plan my week"
save this week
```
"""#
}
