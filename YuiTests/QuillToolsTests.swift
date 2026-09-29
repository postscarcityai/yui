import XCTest
import YuiLines
@testable import Yui

/// Quill's tools in the app (YUI-186): the runtime's replies, verbatim, through the app's own parser and
/// stage on the real thread path (ChatStore.load, as a relaunch reads the server's rows; no demo memory,
/// Chris Sep 28: the 0.5.0 crash hid behind it). Learn a topic (a plan, then a lesson deck ending in a quiz
/// whose answers wait for the end), cards with spaced review (a plan, patches), a problem a step a page,
/// and his three pages kept current by patches. What the runtime keeps (cards, boxes, due days) is in his
/// tables, so the phone keeps nothing of it: a relaunch is the same rows loaded again.
@MainActor
final class QuillToolsTests: XCTestCase {
    /// runtime: Learn something new (the chip), no topic said yet (learnPlan).
    static let learnOpen = #"""
Let's learn something.
```yui
plan@learn "Learn a topic" submit="Teach me"
page "Five minutes, then a quiz" body="Tell me what you want to learn, how long you have and what you know already. I'll make a short lesson, one idea a page, with a quick quiz at the end. What you learn becomes cards you review later, next to World capitals."
form@topic "What do you want to learn?" topic:voice! submit=Next
choose@time "How much time do you have?" "5 minutes"|"10 minutes"|"20 minutes"
choose@know "What do you know about it already?" "Nothing yet"|"The basics"|"Quite a bit"
```
"""#

    /// runtime: the learn plan's Send, 5 minutes, a real lesson JSON (lessonReply).
    static let lesson = #"""
Here's Photosynthesis in a 5 minute lesson. A 3 question quiz at the end. 5 cards go in your review, first one tomorrow.
```yui
deck@lesson-photosynthesis "Photosynthesis" +full
page "Plants make food from light" body="Leaves catch sunlight and turn it into sugar."
page "What goes in" points="Water from the roots"|"Carbon dioxide from the air"|"Light from the sun"
page "The recipe" body="Six of each go in; sugar and oxygen come out."
math 6CO_2 + 6H_2O \rightarrow C_6H_{12}O_6 + 6O_2
page "Where it happens" body="In chloroplasts, the green parts of leaf cells."
choose@quiz-photosynthesis-1 "What gas do plants take in?" "Oxygen"|"Carbon dioxide"|"Nitrogen" answer="Carbon dioxide" why="They breathe in CO2 and give out oxygen."
choose@quiz-photosynthesis-2 "Where does it happen?" "Roots"|"Chloroplasts"|"Flowers" answer="Chloroplasts" why="Chloroplasts hold the chlorophyll."
choose@quiz-photosynthesis-3 "What comes out?" "Sugar and oxygen"|"Water"|"Soil" answer="Sugar and oxygen"
~studying "World capitals" "8 cards. 1 due today." sub="Geography" cta="Review now"
~decks title="Your decks" "Photosynthesis, 5 cards"|"World capitals, 8 cards"
~learn-new "Learn something new" "A topic, how long you have, what you know. A short lesson, then a quiz." cta="Learn a topic"
~walk "Stuck on a problem?" "I'll break it into steps. You answer each one before the next." cta="Walk me through it"
~due 1 "Cards due today" sub="World capitals"
~review-start "Review 1 card" "Think of the answer, then tap again, hard, good or easy." cta="Start review"
```
"""#

    /// runtime: the deck's done, 2 of 3 (quiz answers before it are quiet).
    static let quizDone = #"""
2 of 3. Nice. Photosynthesis is in your review, first cards tomorrow.
```yui
~studying "World capitals" "8 cards. 1 due today." sub="Geography" cta="Review now"
~decks title="Your decks" "Photosynthesis, 5 cards"|"World capitals, 8 cards"
~learn-new "Learn something new" "A topic, how long you have, what you know. A short lesson, then a quiz." cta="Learn a topic"
~walk "Stuck on a problem?" "I'll break it into steps. You answer each one before the next." cta="Walk me through it"
~streak 1 "Day streak" sub="Keep it going today"
~studied bar "Cards reviewed" x=Tue|Wed|Thu|Fri|Sat|Sun|Today y=0|0|0|0|0|0|8
~learned 0 "Cards learned" sub="of 13 cards, box 4 or higher"
~last-quiz "2/3" "Last quiz" sub="Photosynthesis"
```
"""#

    /// runtime: Review my cards, the 8 starter cards due (reviewPlan).
    static let reviewOpen = #"""
```yui
plan@review "Review 8 cards" submit="Save my review"
page "8 cards due" body="Think of the answer before you look. Then tap how it went: Again brings it back today, Easy sends it furthest."
choose@c-c1 "Tokyo" "Again"|"Hard"|"Good"|"Easy" title="Capital of Japan?" tag="World capitals"
choose@c-c2 "Ottawa" "Again"|"Hard"|"Good"|"Easy" title="Capital of Canada?" tag="World capitals"
choose@c-c3 "Canberra" "Again"|"Hard"|"Good"|"Easy" title="Capital of Australia?" tag="World capitals"
choose@c-c4 "Brasilia" "Again"|"Hard"|"Good"|"Easy" title="Capital of Brazil?" tag="World capitals"
choose@c-c5 "Nairobi" "Again"|"Hard"|"Good"|"Easy" title="Capital of Kenya?" tag="World capitals"
choose@c-c6 "Ankara" "Again"|"Hard"|"Good"|"Easy" title="Capital of Turkey?" tag="World capitals"
choose@c-c7 "Wellington" "Again"|"Hard"|"Good"|"Easy" title="Capital of New Zealand?" tag="World capitals"
choose@c-c8 "Cairo" "Again"|"Hard"|"Good"|"Easy" title="Capital of Egypt?" tag="World capitals"
```
"""#

    /// runtime: the review's Send, 1 again, 1 hard, 5 good, 1 easy: patches only.
    static let reviewSaved = #"""
Saved: 8 cards reviewed, 1 to see again today. 1 still due.
```yui
~studying "World capitals" "8 cards. 1 due today." sub="Geography" cta="Review now"
~decks title="Your decks" "World capitals, 8 cards"
~learn-new "Learn something new" "A topic, how long you have, what you know. A short lesson, then a quiz." cta="Learn a topic"
~walk "Stuck on a problem?" "I'll break it into steps. You answer each one before the next." cta="Walk me through it"
~due 1 "Cards due today" sub="World capitals"
~review-start "Review 1 card" "Think of the answer, then tap again, hard, good or easy." cta="Start review"
~streak 1 "Day streak" sub="Keep it going today"
~studied bar "Cards reviewed" x=Tue|Wed|Thu|Fri|Sat|Sun|Today y=0|0|0|0|0|0|8
~learned 0 "Cards learned" sub="of 8 cards, box 4 or higher"
~last-quiz "None" "Last quiz" sub="Finish a lesson's quiz"
```
"""#

    /// runtime: Walk me through a problem (problemPlan).
    static let problemOpen = #"""
```yui
plan@problem "Walk me through a problem" submit="Start"
page "One step at a time" body="Type or say the problem. I'll break it into steps, one a page. You answer each step before the next one shows, so you do the thinking."
form@question "What's the problem?" problem:voice! submit=Next
choose@size "How big should the steps be?" "Small steps"|"Bigger steps"
```
"""#

    /// runtime: the problem's Send, step 1 of 2.
    static let step1 = #"""
Solve 2x + 3 = 11, in 2 steps. Answer each one and the next shows.
```yui
page "Step 1 of 2: Take away 3" body="Get the x term alone: take 3 from both sides."
math 2x + 3 - 3 = 11 - 3
choose@step-solve-2x-3-11-0928-1 "What is 11 - 3?" "7"|"8"|"14" answer="8" why="11 take away 3 is 8."
```
"""#

    /// runtime: step 1 answered wrong (7), step 2 shows.
    static let step2 = #"""
Not quite: it's 8. 11 take away 3 is 8.
```yui
page "Step 2 of 2: Divide by 2" body="Now 2x = 8. Divide both sides by 2."
math \frac{2x}{2} = \frac{8}{2}
choose@step-solve-2x-3-11-0928-2 "So x is?" "4"|"6"|"16" answer="4" why="8 split in two is 4."
```
"""#

    /// runtime: step 2 answered right, the problem is solved.
    static let problemDone = #"""
Right. Solved: x = 4. You got 1 of 2 steps.
```yui
~streak 1 "Day streak" sub="Keep it going today"
~studied bar "Cards reviewed" x=Tue|Wed|Thu|Fri|Sat|Sun|Today y=0|0|0|0|0|0|8
~learned 0 "Cards learned" sub="of 13 cards, box 4 or higher"
~last-quiz "1/2" "Last quiz" sub="Algebra"
```
"""#

    private func row(_ id: String, _ sender: String, _ body: String, kind: String = "text", meta: YLValue? = nil) -> ThreadRow {
        ThreadRow(id: id, sender: sender, body: body, kind: kind, meta: meta, createdAt: ISO8601DateFormatter().string(from: .now))
    }

    private func event(_ id: String, _ line: String, _ preset: String, _ value: [String: YLValue], echo: String? = nil) -> ThreadRow {
        var m: [String: YLValue] = ["id": .string(id), "preset": .string(preset), "value": .object(value)]
        if let echo { m["echo"] = .string(echo) }
        return row("e-\(id)", "user", line, kind: "event", meta: .object(m))
    }

    private func home() -> ThreadRow {
        row("home-quill", "agent", AgentStore.demoHome["quill"]!, meta: .object(["native": .string("home")]))
    }

    private func page(_ store: ChatStore, _ n: Int) -> [YLComponent] {
        store.onPage(n).flatMap { $0.yl?.onPage(n, style: [:]) ?? [] }
    }

    private func fence(_ body: String) -> String {
        body.components(separatedBy: "```yui\n")[1].components(separatedBy: "\n```")[0]
    }

    /// The whole thread after a lesson, a review and a problem, as the server hands it back on open.
    private func thread() -> ChatStore {
        let store = ChatStore()
        store.load([
            home(),
            row("u0", "user", "Review my cards"),
            row("a0", "agent", Self.reviewOpen),
            event("review", "[yui] review plan", "plan", ["plan": .object(["c-c1": .string("Again"), "c-c2": .string("Hard"), "c-c3": .string("Good"),
                                                                            "c-c4": .string("Easy")])], echo: "Saved"),
            row("a1", "agent", Self.reviewSaved),
            row("u1", "user", "Teach me something new"),
            row("a2", "agent", Self.learnOpen),
            event("learn", "[yui] learn plan", "plan", ["plan": .object(["topic": .object(["topic": .string("Photosynthesis")]),
                                                                          "time": .string("5 minutes"), "know": .string("Nothing yet")])], echo: "Photosynthesis"),
            row("a3", "agent", Self.lesson),
            event("quiz-photosynthesis-1", "[yui] quiz-photosynthesis-1 choose", "choose", ["choice": .string("Carbon dioxide"), "correct": .bool(true)], echo: "Carbon dioxide"),
            event("lesson-photosynthesis", "[yui] lesson-photosynthesis deck", "deck", ["done": .bool(true), "score": .number(2), "of": .number(3)]),
            row("a4", "agent", Self.quizDone),
        ])
        return store
    }

    func testTheDemoHomeIsHisFourChipsAndThreePages() {
        let store = ChatStore()
        store.load([home()])
        XCTAssertEqual(AgentHome.chips(store).map(\.label), ["Review my cards", "Learn something new", "Walk me through a problem", "What's due?"])
        XCTAssertEqual(store.screens, [1, 2, 3, 4])
        XCTAssertEqual(page(store, 2).map(\.ylID), ["studying", "decks", "learn-new", "walk"])
        XCTAssertEqual(page(store, 3).map(\.ylID), ["due", "review-start"])
        XCTAssertEqual(page(store, 4).map(\.ylID), ["streak", "studied", "learned", "last-quiz"])
        XCTAssertTrue(store.awaitingYou.isEmpty, "his buttons are tools on standing pages, not asks")
        XCTAssertEqual(store.page, 1, "loading the home moved the person")
    }

    func testEveryReplyParsesCleanAndEveryButtonDoesSomething() {
        for body in [Self.learnOpen, Self.lesson, Self.quizDone, Self.reviewOpen, Self.reviewSaved, Self.problemOpen, Self.step1, Self.step2, Self.problemDone] {
            let yl = YLScreen(fence(body))
            // A patch names something the home drew, so on its own it has no target: that is not a parse error.
            let bad = yl.errors.filter { !($0.message ?? "").hasPrefix("patch: nothing called") }
            XCTAssertTrue(bad.isEmpty, "parse errors \(bad) in:\n\(fence(body))")
            for c in yl.components where c.preset == "card" {
                if c.ylID == "studying" || c.ylID == "review-start" || c.ylID == "learn-new" || c.ylID == "walk" {
                    XCTAssertNotNil(c.string("cta"), "\(c.ylID ?? "") has no button")
                }
            }
        }
    }

    func testLearnATopicIsOneFullScreenPlanTheTopicAndQuestionsLastWithOneSend() {
        let yl = YLScreen(fence(Self.learnOpen))
        let plan = yl.components.first { $0.preset == "plan" }
        XCTAssertEqual(plan?.ylID, "learn")
        XCTAssertEqual(plan?.string("submit"), "Teach me")
        let r = StageChunks.of(yl, scope: "a1")
        XCTAssertEqual(r.chunks.map { $0.line ?? "" }, ["Five minutes, then a quiz"], "how it works first")
        XCTAssertEqual(r.questions.map(\.c.ylID), ["topic", "time", "know"], "the questions come last, one Send")
    }

    func testTheLessonIsADeckOnTheStageAPageAnIdeaAndItsQuizWaitsForTheEnd() {
        let yl = YLScreen(Self.lesson.components(separatedBy: "```yui\n")[1].components(separatedBy: "\n```")[0])
        let deck = yl.components.first { $0.preset == "deck" }
        XCTAssertEqual(deck?.ylID, "lesson-photosynthesis")
        let r = StageChunks.of(yl, scope: "a2")
        XCTAssertEqual(r.chunks.compactMap(\.line), ["Plants make food from light", "What goes in", "The recipe", "Where it happens"])
        XCTAssertEqual(r.questions.map(\.c.ylID), ["quiz-photosynthesis-1", "quiz-photosynthesis-2", "quiz-photosynthesis-3"])
        XCTAssertEqual(r.questions.first?.c.string("answer"), "Carbon dioxide")
        XCTAssertTrue(r.chunks.contains { $0.pic?.preset == "math" }, "the recipe's formula is drawn with its page")
    }

    func testAfterTheLessonHisPagesHoldTheNewDeckAndTheScore() {
        let store = thread()
        let studying = page(store, 2)
        XCTAssertEqual(studying.first { $0.ylID == "decks" }?.strings("items") ?? studying.first { $0.ylID == "decks" }?.strings("options"),
                       ["Photosynthesis, 5 cards", "World capitals, 8 cards"])
        XCTAssertEqual(page(store, 4).first { $0.ylID == "last-quiz" }?.string("value"), "2/3")
        XCTAssertEqual(page(store, 4).first { $0.ylID == "learned" }?.string("sub"), "of 13 cards, box 4 or higher")
        XCTAssertEqual(store.screens, [1, 2, 3, 4], "patches, no new page")
        XCTAssertEqual(store.awaitingYou.map(\.ask.ylID), [], "nothing waits on you")
    }

    func testReviewIsOnePlanEachCardsFrontASRatingAndTheSendPatchesTheDueCount() {
        let yl = YLScreen(fence(Self.reviewOpen))
        let r = StageChunks.of(yl, scope: "r1")
        XCTAssertEqual(r.chunks.compactMap(\.line), ["8 cards due"])
        XCTAssertEqual(r.questions.count, 8)
        XCTAssertEqual(r.questions[0].c.strings("options"), ["Again", "Hard", "Good", "Easy"])
        XCTAssertEqual(r.questions[0].c.string("title"), "Capital of Japan?")
        let store = thread()
        XCTAssertEqual(page(store, 3).first { $0.ylID == "due" }?.number("value"), 1)
        XCTAssertEqual(page(store, 3).first { $0.ylID == "review-start" }?.string("title"), "Review 1 card")
        XCTAssertEqual(page(store, 2).first { $0.ylID == "studying" }?.string("body") ?? page(store, 2).first { $0.ylID == "studying" }?.string("sub"), "8 cards. 1 due today.")
    }

    func testAProblemIsAStepAPageAndTheNextShowsOnlyOnceAnswered() {
        let first = YLScreen(fence(Self.step1)).components
        XCTAssertEqual(first.map(\.preset), ["page", "math", "choose"], "step 1 only")
        XCTAssertEqual(first.last?.string("answer"), "8")
        let second = YLScreen(fence(Self.step2)).components
        XCTAssertEqual(second.map(\.preset), ["page", "math", "choose"], "step 2 only")
        XCTAssertEqual(second.last?.string("answer"), "4")
        let plan = YLScreen(fence(Self.problemOpen)).components
        XCTAssertEqual(plan.map(\.preset), ["plan", "page", "form", "choose"])
        let store = ChatStore()
        store.load([home(), row("u1", "user", "Walk me through a problem"), row("a1", "agent", Self.problemOpen),
                    event("problem", "[yui] problem plan", "plan", ["plan": .object(["size": .string("Small steps")])], echo: "Solve 2x + 3 = 11"),
                    row("a2", "agent", Self.step1)])
        XCTAssertEqual(store.awaitingYou.map(\.ask.ylID), ["step-solve-2x-3-11-0928-1"], "the step waits on the answer, and nothing else does")
        XCTAssertEqual(page(store, 4).first { $0.ylID == "last-quiz" }?.string("value"), "None")
        store.load([home(), row("a3", "agent", Self.problemDone)])
        XCTAssertEqual(page(store, 4).first { $0.ylID == "last-quiz" }?.string("value"), "1/2")
    }

    func testALoadedThreadIsTheSameAfterEveryRelaunchAndSwitch() {
        // The store is rebuilt from the same rows each time, the way a kill or an agent switch reads them.
        var seen: [String] = []
        for _ in 0..<5 {
            let store = thread()
            seen.append((page(store, 2) + page(store, 3) + page(store, 4)).map { "\($0.ylID ?? "")" }.joined(separator: ","))
            XCTAssertEqual(store.screens, [1, 2, 3, 4])
        }
        XCTAssertEqual(Set(seen).count, 1)
    }
}
