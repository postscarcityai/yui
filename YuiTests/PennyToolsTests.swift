import UserNotifications
import XCTest
import YuiLines
@testable import Yui

/// Penny's tools in the app (YUI-185): reminders from `meta.native.reminders` scheduled as
/// local notifications (the whole set replaced per reply, cleared by an empty one, asked
/// for once), This week's saved order and Today's ticks kept on the phone, the mic step
/// that also types, and her pages after the runtime's replies. Everything runs on the real
/// storage path (a UserDefaults suite, read back by a fresh instance as a relaunch would),
/// never the demo account's memory (Chris, Sep 28: the 0.5.0 switch-agent crash hid there).
/// Every agent reply is the runtime's, verbatim (runtime/src/planner.ts, Monday Sep 28 2026).
@MainActor
final class PennyToolsTests: XCTestCase {
    /// runtime/src/planner.ts, verbatim: plan.
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

    /// runtime/src/planner.ts, verbatim: planned.
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

    /// runtime/src/planner.ts, verbatim: tick.
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

    /// runtime/src/planner.ts, verbatim: order.
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

    /// runtime/src/planner.ts, verbatim: review.
    static let review = #"""
```yui
plan@review "Evening review" submit="Wrap up the day"
page "1 done today" body="Nice. 2 still open: done, tomorrow or drop each one." points="Pay the water bill"
choose@r-book-a-haircut "Book a haircut" "Done"|"Tomorrow"|"Drop"
choose@r-groceries "Groceries" "Done"|"Tomorrow"|"Drop"
choose@feel "How did today go?" "Great"|"Okay"|"Rough"
```
"""#

    /// runtime/src/planner.ts, verbatim: reviewed.
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

    /// A notification center that only remembers.
    final class FakeCenter: Reminders.Center {
        var state: UNAuthorizationStatus = .authorized
        var asked = 0
        var requests: [UNNotificationRequest] = []
        func status() async -> UNAuthorizationStatus { state }
        func ask() async -> Bool { asked += 1; state = .authorized; return true }
        func pending() async -> [String] { requests.map(\.identifier) }
        func remove(_ ids: [String]) { requests.removeAll { ids.contains($0.identifier) } }
        func add(_ request: UNNotificationRequest) async {
            requests.removeAll { $0.identifier == request.identifier }
            requests.append(request)
        }
    }

    private var defaults: UserDefaults!
    /// Monday Sep 28 2026, 9 am on the phone's clock: before every reminder in the fixtures.
    private let monday = Reminders.date("2026-09-28T09:00")!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "yui.tests.penny")
        defaults.removePersistentDomain(forName: "yui.tests.penny")
    }

    private func meta(_ items: [[String: String]]) -> YLValue {
        .object(["native": .object(["plannertool": .string("planned"),
                                    "reminders": .array(items.map { .object($0.mapValues { .string($0) }) })])])
    }
    private let dentist = ["key": "call-the-dentist", "text": "Call the dentist, 9:00 am", "at": "2026-09-29T08:50"]
    private let mom = ["key": "call-mom", "text": "Call mom, 5:00 pm", "at": "2026-09-29T16:50"]

    // MARK: Reminders

    func testAPlannedWeeksReminderIsScheduledAtItsLocalTimeAndOpensPenny() async throws {
        let center = FakeCenter()
        let r = Reminders(defaults: defaults, center: center)
        XCTAssertTrue(r.take(meta: meta([dentist]), agent: "penny-1", name: "Penny", createdAt: "2026-09-28T13:00:00+00:00",
                             live: true, now: monday))
        await r.settle()
        XCTAssertEqual(center.requests.map(\.identifier), ["yui.reminder.penny-1.call-the-dentist"])
        let req = try XCTUnwrap(center.requests.first)
        XCTAssertEqual(req.content.title, "Penny")
        XCTAssertEqual(req.content.body, "Call the dentist, 9:00 am")
        XCTAssertEqual(req.content.userInfo["agent_id"] as? String, "penny-1", "a tap opens her thread")
        let when = try XCTUnwrap((req.trigger as? UNCalendarNotificationTrigger)?.dateComponents)
        XCTAssertEqual([when.year, when.month, when.day, when.hour, when.minute], [2026, 9, 29, 8, 50], "the phone's own clock")
        XCTAssertFalse((req.trigger as? UNCalendarNotificationTrigger)?.repeats ?? true)
    }

    func testEachSetReplacesTheLastAndAnEmptyOneClearsThem() async {
        let center = FakeCenter()
        // Another agent's reminder is never touched.
        await center.add(UNNotificationRequest(identifier: "yui.reminder.arnold-1.leg-day", content: .init(), trigger: nil))
        let r = Reminders(defaults: defaults, center: center)
        r.take(meta: meta([dentist]), agent: "penny-1", name: "Penny", createdAt: "2026-09-28T13:00:00+00:00", live: true, now: monday)
        r.take(meta: meta([dentist, mom]), agent: "penny-1", name: "Penny", createdAt: "2026-09-28T13:01:00+00:00", live: true, now: monday)
        await r.settle()
        XCTAssertEqual(Set(center.requests.map(\.identifier)),
                       ["yui.reminder.arnold-1.leg-day", "yui.reminder.penny-1.call-the-dentist", "yui.reminder.penny-1.call-mom"])
        // The dentist is done: the next set leaves it out.
        r.take(meta: meta([mom]), agent: "penny-1", name: "Penny", createdAt: "2026-09-28T13:02:00+00:00", live: true, now: monday)
        await r.settle()
        XCTAssertEqual(Set(center.requests.map(\.identifier)), ["yui.reminder.arnold-1.leg-day", "yui.reminder.penny-1.call-mom"])
        r.take(meta: meta([]), agent: "penny-1", name: "Penny", createdAt: "2026-09-28T13:03:00+00:00", live: true, now: monday)
        await r.settle()
        XCTAssertEqual(center.requests.map(\.identifier), ["yui.reminder.arnold-1.leg-day"], "an empty set clears hers")
        XCTAssertEqual(Reminders(defaults: defaults, center: center).saved("penny-1"), [])
    }

    func testAReplyWithoutRemindersChangesNothing() async {
        let center = FakeCenter()
        let r = Reminders(defaults: defaults, center: center)
        r.take(meta: meta([dentist]), agent: "penny-1", name: "Penny", createdAt: "2026-09-28T13:00:00+00:00", live: true, now: monday)
        let tick = YLValue.object(["native": .object(["plannertool": .string("tick")])])
        XCTAssertFalse(r.take(meta: tick, agent: "penny-1", name: "Penny", createdAt: "2026-09-28T13:05:00+00:00", live: true, now: monday))
        XCTAssertFalse(r.take(meta: nil, agent: "penny-1", name: "Penny", createdAt: "2026-09-28T13:06:00+00:00", live: true, now: monday))
        await r.settle()
        XCTAssertEqual(center.requests.count, 1)
    }

    func testAnOlderRowReadOnOpenNeverUndoesANewerSet() async {
        let center = FakeCenter()
        let r = Reminders(defaults: defaults, center: center)
        r.take(meta: meta([dentist, mom]), agent: "penny-1", name: "Penny", createdAt: "2026-09-28T13:05:00+00:00", live: true, now: monday)
        await r.settle()
        // A relaunch reads the thread from the top: the first plan's set comes by again.
        let again = Reminders(defaults: defaults, center: center)
        XCTAssertFalse(again.take(meta: meta([dentist]), agent: "penny-1", name: "Penny", createdAt: "2026-09-28T13:00:00+00:00",
                                  live: false, now: monday))
        await again.settle()
        XCTAssertEqual(center.requests.count, 2)
        XCTAssertEqual(again.saved("penny-1").map(\.key), ["call-the-dentist", "call-mom"], "read back from UserDefaults")
        // What is kept is plain plist values: a dictionary per reminder, and the reply's time.
        XCTAssertNotNil(defaults.array(forKey: Reminders.key("penny-1")) as? [[String: String]])
        XCTAssertNotNil(defaults.object(forKey: Reminders.key("penny-1") + ".at") as? Date)
    }

    func testPermissionIsAskedOnceAndOnlyForALiveReply() async {
        let center = FakeCenter()
        center.state = .notDetermined
        let r = Reminders(defaults: defaults, center: center)
        // History on open: kept, never asks.
        r.take(meta: meta([dentist]), agent: "penny-1", name: "Penny", createdAt: "2026-09-28T13:00:00+00:00", live: false, now: monday)
        await r.settle()
        XCTAssertEqual(center.asked, 0)
        XCTAssertTrue(center.requests.isEmpty, "no permission, nothing scheduled")
        r.take(meta: meta([dentist]), agent: "penny-1", name: "Penny", createdAt: "2026-09-28T13:01:00+00:00", live: true, now: monday)
        await r.settle()
        XCTAssertEqual(center.asked, 1, "the first live reply with a reminder asks")
        XCTAssertEqual(center.requests.count, 1)
        // Turned down: never asked again, and nothing is scheduled.
        center.state = .denied
        center.requests = []
        let later = Reminders(defaults: defaults, center: center)
        later.take(meta: meta([dentist, mom]), agent: "penny-1", name: "Penny", createdAt: "2026-09-28T13:02:00+00:00", live: true, now: monday)
        await later.settle()
        XCTAssertEqual(center.asked, 1)
        XCTAssertTrue(center.requests.isEmpty)
        XCTAssertEqual(later.saved("penny-1").count, 2, "still kept for when they turn it on")
    }

    func testAReminderInThePastIsNotScheduledAndABadOneIsSkipped() async {
        let center = FakeCenter()
        let r = Reminders(defaults: defaults, center: center)
        let late = Reminders.date("2026-09-29T12:00")! // Tuesday noon: past 8:50, before 4:50 pm
        let bad = ["key": "x", "text": "?", "at": "tomorrow-ish"]
        r.take(meta: meta([dentist, mom, bad]), agent: "penny-1", name: "Penny", createdAt: "2026-09-29T13:00:00+00:00",
               live: true, now: late)
        await r.settle()
        XCTAssertEqual(center.requests.map(\.identifier), ["yui.reminder.penny-1.call-mom"])
        XCTAssertEqual(r.saved("penny-1").map(\.key), ["call-the-dentist", "call-mom"])
    }

    func testTheRuntimesPlannedReplyCarriesTheSetTheAppReads() {
        let meta = YLValue.object(["turn": .array([.string("row-1")]), "native": .object([
            "plannertool": .string("planned"),
            "reminders": .array([.object(["key": .string("call-the-dentist"), "text": .string("Call the dentist, 9:00 am"),
                                          "at": .string("2026-09-29T08:50")])])])])
        XCTAssertEqual(Reminders.items(meta: meta), [.init(key: "call-the-dentist", text: "Call the dentist, 9:00 am", at: "2026-09-29T08:50")])
        XCTAssertNil(Reminders.items(meta: .object(["native": .string("home")])), "the home row says nothing about reminders")
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        let at = Reminders.date("2026-09-29T08:50", zone: ny.timeZone)!
        XCTAssertEqual(ny.dateComponents([.hour, .minute], from: at), DateComponents(hour: 8, minute: 50))
    }

    // MARK: Her pages

    private func thread(_ replies: [(String, YLValue?)]) -> ChatStore {
        let at = ISO8601DateFormatter().string(from: .now)
        let store = ChatStore()
        var rows = [ThreadRow(id: "home-penny", sender: "agent", body: AgentStore.demoHome["penny"]!, kind: "text",
                              meta: .object(["native": .string("home")]), createdAt: at)]
        for (i, r) in replies.enumerated() {
            rows.append(ThreadRow(id: "a\(i)", sender: "agent", body: r.0, kind: "text", meta: r.1, createdAt: at))
            // Each plan was sent, as the phone sends it: one {plan} event.
            for plan in ["weekplan", "review"] where r.0.contains("plan@\(plan) ") {
                rows.append(ThreadRow(id: "e\(i)", sender: "user", body: "[yui] \(plan) plan", kind: "event",
                                      meta: .object(["id": .string(plan), "preset": .string("plan"),
                                                     "value": .object(["plan": .object(["feel": .string("Okay")])]),
                                                     "echo": .string("Sent")]), createdAt: at))
            }
        }
        store.load(rows)
        return store
    }

    private func page(_ store: ChatStore, _ n: Int) -> [YLComponent] {
        store.onPage(n).flatMap { $0.yl?.onPage(n, style: [:]) ?? [] }
    }

    private func week(_ store: ChatStore) -> (rows: [YLComponent], mark: Int) {
        let all = store.onPage(3).flatMap { $0.yl?.components ?? [] }.filter { $0.page == 3 }
        let rows = all.filter { ["done", "now", "next"].contains($0.preset) }
        return (rows, markAt(rows.map(\.preset)))
    }

    func testHerHomeIsTodayAndThisWeekWithFourShortcuts() {
        let store = thread([])
        XCTAssertEqual(store.screens, [1, 2, 3])
        XCTAssertEqual(page(store, 2).map(\.ylID), ["next-task", "today", "wrap"])
        XCTAssertEqual(page(store, 3).first?.preset, "timeline")
        XCTAssertEqual(AgentHome.chips(store).map(\.id), ["plan", "todo", "next", "review"], "Plan my week first")
    }

    func testAPlannedWeekLandsOnThisWeekAndTodayWithNothingWaitingOnYou() {
        let store = thread([(Self.plan, nil), (Self.planned, nil)])
        let today = page(store, 2)
        XCTAssertEqual(today.first { $0.ylID == "next-task" }?.string("title"), "Pay the water bill")
        XCTAssertEqual(today.first { $0.ylID == "today" }?.strings("items"), ["Pay the water bill", "Groceries", "Pick up the dry cleaning"])
        let w = week(store)
        XCTAssertEqual(w.rows.map(\.ylID), ["wk-pay-the-water-bill", "wk-groceries", "wk-pick-up-the-dry-cleaning",
                                            "wk-call-the-dentist", "wk-book-a-haircut"])
        XCTAssertEqual(w.mark, 0, "nothing done yet: Today sits on top")
        XCTAssertTrue(page(store, 3).first?.flag("reorder") == true, "Edit order on This week")
        XCTAssertEqual(store.awaitingYou.map(\.ask.ylID), [], "her pages' pickers read as waiting on you")
    }

    func testATickPatchMovesTheTodayMarkInPlace() {
        let store = thread([(Self.plan, nil), (Self.planned, nil), (Self.tick, nil)])
        let w = week(store)
        XCTAssertEqual(w.rows.first?.preset, "done", "the ticked task is done in place")
        XCTAssertEqual(w.rows.first?.ylID, "wk-pay-the-water-bill")
        XCTAssertEqual(w.mark, 1, "Today moved past it")
        XCTAssertEqual(w.rows.count, 5, "nothing else moved")
        XCTAssertEqual(page(store, 2).first { $0.ylID == "next-task" }?.string("title"), "Groceries")
        XCTAssertEqual(page(store, 2).first { $0.ylID == "today" }?.strings("items"), ["Groceries", "Pick up the dry cleaning"])
    }

    func testATickOnAPageShesKeptGoesToHerQuietly() {
        // A tick is a quiet event: no echo, nothing finished, so it only goes out on a kept page of a native agent.
        var e = YLEvent(id: "today", preset: "list", value: ["item": .string("Groceries"), "checked": .bool(true)], echo: nil)
        XCTAssertFalse(e.relays, "a checklist tick is still quiet everywhere else")
        e.keepsPage = true
        XCTAssertFalse(e.relays, "no working row: it is not owed an answer")
        XCTAssertEqual(e.line, "[yui] today list checked item=Groceries")
    }

    // MARK: This week's order

    func testASavedOrderIsKeptOnThePhoneWhileTheDrawingStands() {
        let line = ["groceries", "pick-up-the-dry-cleaning", "call-the-dentist", "book-a-haircut"]
        let order = ["book-a-haircut", "groceries", "pick-up-the-dry-cleaning", "call-the-dentist"]
        TimelineOrders(defaults: defaults).save("penny-1", "week", line: line, order: order)
        // A relaunch: only UserDefaults.
        let again = TimelineOrders(defaults: defaults)
        XCTAssertEqual(again.order("penny-1", "week", line: line), order)
        XCTAssertNil(again.order("basil-1", "week", line: line), "another agent's week")
        // Patches: groceries done (it leaves the queue) and a new task joins at the end. Same drawing.
        XCTAssertEqual(again.order("penny-1", "week", line: ["pick-up-the-dry-cleaning", "call-the-dentist", "book-a-haircut", "call-mom"]), order)
        // Drawn again in another order (Move a task): the saved order goes for good.
        XCTAssertNil(again.order("penny-1", "week", line: ["call-the-dentist", "groceries", "pick-up-the-dry-cleaning", "book-a-haircut"]))
        XCTAssertNil(again.order("penny-1", "week", line: line))
        XCTAssertNil(defaults.object(forKey: TimelineOrders.key("penny-1", "week")))
        // An unnamed timeline is not kept.
        TimelineOrders(defaults: defaults).save("penny-1", "n4", line: line, order: order)
        XCTAssertNil(TimelineOrders(defaults: defaults).order("penny-1", "n4", line: line))
    }

    func testTheOrderReplyPatchesTheRowsInPlace() {
        let store = thread([(Self.plan, nil), (Self.planned, nil), (Self.tick, nil), (Self.order, nil)])
        let w = week(store)
        XCTAssertEqual(w.rows.first { $0.ylID == "wk-book-a-haircut" }?.string("at"), "Today", "the haircut took today's place")
        XCTAssertEqual(w.rows.first { $0.ylID == "wk-pick-up-the-dry-cleaning" }?.string("at"), "Tomorrow")
        XCTAssertEqual(w.mark, 1)
        XCTAssertEqual(page(store, 2).first { $0.ylID == "next-task" }?.string("title"), "Book a haircut")
    }

    // MARK: Plan my week and the evening review

    func testPlanMyWeekIsOneFlowWithTheMicFirstAndTheQuestionsLast() {
        let yl = YLScreen(Self.plan.components(separatedBy: "```yui\n")[1].components(separatedBy: "\n```")[0])
        let r = StageChunks.of(yl, scope: "a1")
        XCTAssertEqual(r.questions.map(\.c.ylID), ["dump", "busy", "pace", "remind"], "one screen of questions, one Send")
        XCTAssertEqual(r.questions.first?.c.preset, "mic")
        XCTAssertEqual(r.plan?.string("submit"), "Plan my week")
        // What the Send carries: the mic's words as its answer, like any step.
        let said = YLEvent(id: "dump", preset: "mic", value: ["transcript": .string("Call the dentist Tuesday at 9")], echo: "Call the dentist Tuesday at 9")
        XCTAssertEqual(YLComponent.answerValue(said), .string("Call the dentist Tuesday at 9"))
        let steps = yl.components.filter { $0.inGroup == "weekplan" }
        XCTAssertEqual(YLComponent.foldText(steps, ["dump": .string("Groceries"), "pace": .string("2 or 3")]),
                       "Everything on your plate this week: Groceries\nHow many things a day? 2 or 3")
    }

    func testTheEveningReviewIsOnePlanAndLandsAsPatches() {
        let yl = YLScreen(Self.review.components(separatedBy: "```yui\n")[1].components(separatedBy: "\n```")[0])
        let r = StageChunks.of(yl, scope: "a5")
        XCTAssertEqual(r.questions.map(\.c.ylID), ["r-book-a-haircut", "r-groceries", "feel"])
        XCTAssertEqual(r.plan?.string("submit"), "Wrap up the day")
        let store = thread([(Self.plan, nil), (Self.planned, nil), (Self.tick, nil), (Self.order, nil),
                            (Self.review, nil), (Self.reviewed, nil)])
        let w = week(store)
        XCTAssertEqual(w.rows.filter { $0.preset == "done" }.map(\.ylID), ["wk-pay-the-water-bill", "wk-groceries"])
        XCTAssertEqual(page(store, 2).first { $0.ylID == "today" }?.strings("items"), ["Book a haircut"])
    }
}
