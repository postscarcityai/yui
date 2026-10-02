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
}
