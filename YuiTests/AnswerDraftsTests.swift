import XCTest
import YuiLines
@testable import Yui

/// Forms keep your answers (feedback NOTE-19357): what a person typed or picked in a question
/// and has not sent is kept on the phone, per agent, reply, component and field, until it goes.
/// UserDefaults is the real path a relaunch reads, so every check here reads it back through a
/// fresh store.
@MainActor
final class AnswerDraftsTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "yui.tests.answers")
        defaults.removePersistentDomain(forName: "yui.tests.answers")
    }

    private let form: YLValue = .object(["name": .string("Chris"), "role": .string("Founder")])

    func testADraftIsKeptPerAgentReplyComponentAndFieldAndSurvivesARelaunch() {
        let drafts = AnswerDrafts(defaults: defaults)
        drafts.set("yui-1", "r1#0", "about", "form", form)
        XCTAssertEqual(drafts.draft("yui-1", "r1#0", "about", "form"), form)
        // Another agent, another reply, another component and another field all start empty.
        XCTAssertNil(drafts.draft("penny-1", "r1#0", "about", "form"))
        XCTAssertNil(drafts.draft("yui-1", "r2#0", "about", "form"))
        XCTAssertNil(drafts.draft("yui-1", "r1#0", "budget", "form"))
        XCTAssertNil(drafts.draft("yui-1", "r1#0", "about", "other"))
        // A relaunch: nothing in memory, only UserDefaults.
        XCTAssertEqual(AnswerDrafts(defaults: defaults).draft("yui-1", "r1#0", "about", "form"), form)
    }

    func testBlankAndKeyShapedValuesAreNeverKept() {
        let drafts = AnswerDrafts(defaults: defaults)
        drafts.set("yui-1", "r1#0", "n1", "text", .string("   \n"))
        drafts.set("yui-1", "r1#0", "n2", "picked", .array([]))
        drafts.set("yui-1", "r1#0", "n3", "form", .object(["name": .string(""), "role": .string(" ")]))
        drafts.set("yui-1", "r1#0", "n4", "form", .object(["note": .string("my key is \(VaultTests.replicate)")]))
        let back = AnswerDrafts(defaults: defaults)
        for (id, field) in [("n1", "text"), ("n2", "picked"), ("n3", "form"), ("n4", "form")] {
            XCTAssertNil(back.draft("yui-1", "r1#0", id, field), "\(id) was kept")
        }
        XCTAssertNil(defaults.object(forKey: AnswerDrafts.storeKey("yui-1")), "nothing worth keeping leaves nothing behind")
        // A toggle left off or a number is something the person set.
        XCTAssertFalse(AnswerDrafts.isEmpty(.object(["ok": .bool(false)])))
        XCTAssertFalse(AnswerDrafts.isEmpty(.number(0)))
    }

    func testAKeyTypedOverADraftTakesTheDraftAway() {
        let drafts = AnswerDrafts(defaults: defaults)
        drafts.set("yui-1", "r1#0", "n1", "text", .string("Call the dentist"))
        drafts.set("yui-1", "r1#0", "n1", "text", .string("Call the dentist \(VaultTests.anthropic)"))
        XCTAssertNil(AnswerDrafts(defaults: defaults).draft("yui-1", "r1#0", "n1", "text"))
    }

    func testClearingAComponentTakesEveryFieldOfItAndNothingElse() {
        let drafts = AnswerDrafts(defaults: defaults)
        drafts.set("yui-1", "r1#0", "who", "picked", .array([.string("Clients")]))
        drafts.set("yui-1", "r1#0", "who", "other", .string("Friends of"))
        drafts.set("yui-1", "r1#0", "whom", "picked", .array([.string("Press")]))
        drafts.set("yui-1", "r2#0", "who", "picked", .array([.string("Press")]))
        drafts.clear("yui-1", "r1#0", "who")
        let back = AnswerDrafts(defaults: defaults)
        XCTAssertNil(back.draft("yui-1", "r1#0", "who", "picked"))
        XCTAssertNil(back.draft("yui-1", "r1#0", "who", "other"))
        XCTAssertNotNil(back.draft("yui-1", "r1#0", "whom", "picked"), "a component whose id starts the same stays")
        XCTAssertNotNil(back.draft("yui-1", "r2#0", "who", "picked"), "the same id in another reply stays")
        // Nil forgets one field.
        back.set("yui-1", "r1#0", "whom", "picked", nil)
        XCTAssertNil(AnswerDrafts(defaults: defaults).draft("yui-1", "r1#0", "whom", "picked"))
    }

    func testASentPlanOrFlowTakesItsQuestionsDraftsWithIt() {
        let drafts = AnswerDrafts(defaults: defaults)
        drafts.set("yui-1", "r1#0", "about", "form", form)
        drafts.set("yui-1", "r1#0", "pages", "picked", .array([.string("Work")]))
        drafts.set("yui-1", "r1#0", "later", "text", .string("Not in this plan"))
        let plan = YLEvent(id: "site", preset: "plan", value: ["plan": .object(["about": form, "pages": .array([.string("Work")])])],
                           echo: "About you: Chris")
        drafts.sent(plan, scope: "r1#0", agent: "yui-1")
        XCTAssertNil(drafts.draft("yui-1", "r1#0", "about", "form"))
        XCTAssertNil(drafts.draft("yui-1", "r1#0", "pages", "picked"))
        XCTAssertNotNil(drafts.draft("yui-1", "r1#0", "later", "text"), "a question the plan did not carry keeps its words")

        drafts.set("yui-1", "r3#0", "q1", "picked", .array([.string("Yes")]))
        let flow = YLEvent(id: "intake", preset: "flow", value: ["flow": .object(["q1": .string("Yes")]), "path": .array([.string("q1")])],
                           echo: "Ready? Yes")
        drafts.sent(flow, scope: "r3#0", agent: "yui-1")
        XCTAssertNil(AnswerDrafts(defaults: defaults).draft("yui-1", "r3#0", "q1", "picked"))
    }

    func testEachAgentKeepsOnlyItsNewestDrafts() {
        let drafts = AnswerDrafts(defaults: defaults)
        for i in 0..<(AnswerDrafts.cap + 5) { drafts.set("yui-1", "r\(i)#0", "n1", "text", .string("words \(i)")) }
        let back = AnswerDrafts(defaults: defaults)
        XCTAssertNil(back.draft("yui-1", "r0#0", "n1", "text"), "the oldest drops off the end")
        XCTAssertEqual(back.draft("yui-1", "r\(AnswerDrafts.cap + 4)#0", "n1", "text"), .string("words \(AnswerDrafts.cap + 4)"))
        let kept = (0..<(AnswerDrafts.cap + 5)).filter { back.draft("yui-1", "r\($0)#0", "n1", "text") != nil }
        XCTAssertEqual(kept.count, AnswerDrafts.cap)
    }

    func testNoAgentIsKeptInMemoryOnlyAndNoScopeIsNotKept() {
        let drafts = AnswerDrafts(defaults: defaults)
        drafts.set("", "r1#0", "n1", "text", .string("A chat on its own"))
        XCTAssertEqual(drafts.draft("", "r1#0", "n1", "text"), .string("A chat on its own"))
        XCTAssertNil(AnswerDrafts(defaults: defaults).draft("", "r1#0", "n1", "text"), "no agent, nothing on disk")
        drafts.set("yui-1", "", "n1", "text", .string("No reply to keep it under"))
        XCTAssertNil(drafts.draft("yui-1", "", "n1", "text"))
    }

    /// The store takes a draft away the moment its answer goes from this phone; a quiet event does not.
    func testAnAnswerSentThroughTheStoreClearsItsDraft() {
        let store = ChatStore()
        let drafts = AnswerDrafts(defaults: defaults)
        store.drafts = drafts
        store.load(Array(ReopenAnswersTests.rows.prefix(1)))
        let components = store.messages[0].yl!.components
        let pick = components[1], formC = components[4]
        drafts.set("", "r1#0", pick.ylID, "picked", .array([.string("Bench")]))
        drafts.set("", "r1#0", formC.ylID, "form", .object(["name": .string("Chris")]))

        store.receive(pick.event(["open": .bool(true)]))
        XCTAssertNotNil(drafts.draft("", "r1#0", pick.ylID, "picked"), "a quiet event is not an answer")
        store.receive(pick.answer(["picked": .array([.string("Bench")])], echo: "Bench", changed: false))
        XCTAssertNil(drafts.draft("", "r1#0", pick.ylID, "picked"))
        XCTAssertNotNil(drafts.draft("", "r1#0", formC.ylID, "form"), "another question keeps its draft")
    }

    /// A pick handed back to its host on appear says so to the host only: the agent never reads it.
    func testARestoredEventSendsNothingExtra() {
        var e = YLEvent(id: "n1", preset: "choose", value: ["choice": .string("Push")], echo: "Push")
        let line = e.line, json = e.json
        e.restored = true
        XCTAssertEqual(e.line, line)
        XCTAssertEqual(e.json, json)
        XCTAssertFalse(e.json.contains("restored"))
    }

    // MARK: A week, then gone

    private let day: TimeInterval = 24 * 60 * 60

    func testADraftAWeekOldGoesOnReadAndOnDisk() {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let drafts = AnswerDrafts(defaults: defaults, now: { clock })
        drafts.set("yui-1", "r1#0", "about", "form", form)
        clock += 6 * day
        XCTAssertEqual(drafts.draft("yui-1", "r1#0", "about", "form"), form, "six days on it is still there")
        clock += 2 * day
        XCTAssertNil(drafts.draft("yui-1", "r1#0", "about", "form"), "eight days on it is gone")
        // Gone from disk too: a store whose clock says it is fresh still finds nothing.
        let earlier = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(AnswerDrafts(defaults: defaults, now: { earlier }).draft("yui-1", "r1#0", "about", "form"))
        XCTAssertNil(defaults.object(forKey: AnswerDrafts.storeKey("yui-1")))
    }

    func testAWriteDropsTheOldDraftsAndKeepsTheNewOne() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        AnswerDrafts(defaults: defaults, now: { start }).set("yui-1", "r1#0", "old", "text", .string("Last week"))
        let later = start.addingTimeInterval(8 * day)
        AnswerDrafts(defaults: defaults, now: { later }).set("yui-1", "r2#0", "new", "text", .string("Today"))
        // Read back with the first clock: the old one would still be fresh, so only the write could have dropped it.
        let back = AnswerDrafts(defaults: defaults, now: { start })
        XCTAssertNil(back.draft("yui-1", "r1#0", "old", "text"))
        XCTAssertEqual(back.draft("yui-1", "r2#0", "new", "text"), .string("Today"))
    }

    func testTypingAgainKeepsADraftYoung() {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let drafts = AnswerDrafts(defaults: defaults, now: { clock })
        drafts.set("yui-1", "r1#0", "n1", "text", .string("Call the"))
        clock += 5 * day
        drafts.set("yui-1", "r1#0", "n1", "text", .string("Call the dentist"))
        clock += 5 * day
        XCTAssertEqual(drafts.draft("yui-1", "r1#0", "n1", "text"), .string("Call the dentist"))
    }

    // MARK: Where a plan was left

    func testAPlanKeepsItsStepReviewAndAnswersAndComesBackOnARelaunch() {
        let drafts = AnswerDrafts(defaults: defaults)
        let place = PlanPlace(step: "budget", review: false, answers: ["about": form, "who": .string("Clients")])
        drafts.setPlace("yui-1", "r1#0", "site", place)
        let back = AnswerDrafts(defaults: defaults).place("yui-1", "r1#0", "site")
        XCTAssertEqual(back, place)
        XCTAssertEqual(back?.index(in: ["intro", "about", "who", "budget"]), 3, "reopens on the step it was on")
        XCTAssertNil(back?.index(in: ["intro", "about"]), "a step that is gone reopens nowhere new")
        XCTAssertNil(AnswerDrafts(defaults: defaults).place("yui-1", "r2#0", "site"), "another reply's plan starts at the start")

        drafts.setPlace("yui-1", "r1#0", "site", PlanPlace(step: "budget", review: true, answers: ["who": .string("Press")]))
        XCTAssertEqual(AnswerDrafts(defaults: defaults).place("yui-1", "r1#0", "site")?.review, true)
    }

    func testTheFirstStepWithNothingSetKeepsNothing() {
        let drafts = AnswerDrafts(defaults: defaults)
        drafts.setPlace("yui-1", "r1#0", "site", PlanPlace(step: "who", answers: [:]))
        drafts.setPlace("yui-1", "r1#0", "site", PlanPlace())
        XCTAssertNil(PlanPlace().value)
        XCTAssertNil(drafts.place("yui-1", "r1#0", "site"), "back on the first step with nothing set: nothing to come back to")
        XCTAssertNil(defaults.object(forKey: AnswerDrafts.storeKey("yui-1")))
        // The first step with an answer still keeps the answer.
        drafts.setPlace("yui-1", "r1#0", "site", PlanPlace(answers: ["about": form]))
        XCTAssertEqual(drafts.place("yui-1", "r1#0", "site")?.answers["about"], form)
        XCTAssertNil(drafts.place("yui-1", "r1#0", "site")?.step)
    }

    func testASentPlanTakesItsPlaceWithIt() {
        let drafts = AnswerDrafts(defaults: defaults)
        drafts.setPlace("yui-1", "r1#0", "site", PlanPlace(step: "budget", answers: ["about": form]))
        drafts.set("yui-1", "r1#0", "about", "form", form)
        let plan = YLEvent(id: "site", preset: "plan", value: ["plan": .object(["about": form])], echo: "About you: Chris")
        drafts.sent(plan, scope: "r1#0", agent: "yui-1")
        let back = AnswerDrafts(defaults: defaults)
        XCTAssertNil(back.place("yui-1", "r1#0", "site"), "a sent plan never reopens mid-way")
        XCTAssertNil(back.draft("yui-1", "r1#0", "about", "form"))
    }

    func testAPlanPlaceAgesOutLikeAnyDraft() {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let drafts = AnswerDrafts(defaults: defaults, now: { clock })
        drafts.setPlace("yui-1", "r1#0", "site", PlanPlace(step: "budget"))
        clock += 8 * day
        XCTAssertNil(drafts.place("yui-1", "r1#0", "site"))
    }

    /// A flow already keeps its own run (step and answers); one never sent and left for a week starts over.
    func testAFlowRunLeftAWeekStartsOverButASentOneStays() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var run = FlowRun()
        run.events["goal"] = ["choice": .string("Get stronger")]
        run.step = "days"
        run.save("r1#0", "intake", in: defaults, now: start)
        XCTAssertEqual(FlowRun.load("r1#0", "intake", in: defaults, now: start.addingTimeInterval(6 * day))?.step, "days",
                       "six days on it reopens on the step it was on")
        XCTAssertNil(FlowRun.load("r1#0", "intake", in: defaults, now: start.addingTimeInterval(8 * day)))
        XCTAssertNil(defaults.data(forKey: FlowRun.key("r1#0", "intake")), "an aged-out run leaves nothing behind")

        run.sent = true
        run.save("r1#0", "intake", in: defaults, now: start)
        XCTAssertEqual(FlowRun.load("r1#0", "intake", in: defaults, now: start.addingTimeInterval(30 * day))?.sent, true,
                       "a sent flow comes back sent")
    }
}
