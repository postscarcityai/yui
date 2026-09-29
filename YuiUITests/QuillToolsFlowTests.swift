import XCTest

/// Quill's tools, the whole way (YUI-186): Learn something new from his home chip, one full-screen plan
/// (the topic, how long, what you know, one Send), the lesson landing as a deck ending in a quiz, his pages
/// drawn again by patches; Review my cards (a rating a card, one Send, the due count patched); Walk me
/// through a problem (one step a page, the next only once answered). Then the app is killed and relaunched
/// from the server's rows and five trips to another agent and back leave his pages as they were (Chris,
/// Sep 28: the 0.5.0 switch-agent crash hid behind the demo account's memory). Every agent reply is
/// runtime/src/study.ts's, verbatim. Demo account, no network. `YUI_SHOTS=<dir>` saves screenshots.
final class QuillToolsFlowTests: XCTestCase {
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

    /// A reply that says nothing (a quiz answer is quiet): the demo answers every relayed tap in turn.
    static let quiet = "```yui\n```"

    private var appearance = "light"
    private let tmp = FileManager.default.temporaryDirectory

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "quill-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "quill-\(appearance)-\(name)"
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

    /// The stage's Next, until `there` (a reply plays a part at a time, a deck a page at a time).
    private func forward(_ app: XCUIApplication, max: Int = 8, _ there: () -> Bool) {
        for _ in 0..<max where !there() {
            let next = app.buttons["stage-next"]
            if next.exists, next.isHittable, next.isEnabled { next.tap() } else { return }
        }
    }

    private func write(_ name: String, _ object: Any) throws -> String {
        let url = tmp.appending(path: name)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return url.path
    }

    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiAgent", "quill", "-appearance", appearance] + args
        app.launch()
        return app
    }

    private func events(_ log: String) -> [[String: Any]] {
        ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    /// The thread as the server hands it back on open: the home, then every row the flow wrote.
    private func rows(_ home: String) -> [[String: Any]] {
        func row(_ id: String, _ sender: String, _ body: String, _ at: Int, kind: String = "text", meta: [String: Any]? = nil) -> [String: Any] {
            var r: [String: Any] = ["id": id, "sender": sender, "kind": kind, "body": body,
                                    "created_at": String(format: "2026-09-28T16:00:%02d+00:00", at)]
            if let meta { r["meta"] = meta }
            return r
        }
        return [
            row("home-quill", "agent", home, 0, meta: ["native": "home"]),
            row("u0", "user", "Review my cards", 1),
            row("a0", "agent", Self.reviewOpen, 2),
            row("e0", "user", "[yui] review plan", 3, kind: "event",
                meta: ["id": "review", "preset": "plan", "value": ["plan": ["c-c1": "Again", "c-c2": "Hard", "c-c3": "Good", "c-c4": "Easy",
                                                                             "c-c5": "Good", "c-c6": "Good", "c-c7": "Good", "c-c8": "Good"]],
                       "echo": "Saved"]),
            row("a1", "agent", Self.reviewSaved, 4),
            row("u1", "user", "Teach me something new", 5),
            row("a2", "agent", Self.learnOpen, 6),
            row("e1", "user", "[yui] learn plan", 7, kind: "event",
                meta: ["id": "learn", "preset": "plan", "value": ["plan": ["topic": ["topic": "Photosynthesis"], "time": "5 minutes", "know": "Nothing yet"]],
                       "echo": "Photosynthesis"]),
            row("a3", "agent", Self.lesson, 8),
            row("e2", "user", "[yui] lesson-photosynthesis deck", 9, kind: "event",
                meta: ["id": "lesson-photosynthesis", "preset": "deck", "value": ["done": true, "score": 2, "of": 3]]),
            row("a4", "agent", Self.quizDone, 10),
            row("u3", "user", "Walk me through a problem", 11),
            row("a5", "agent", Self.problemOpen, 12),
            row("e3", "user", "[yui] problem plan", 13, kind: "event",
                meta: ["id": "problem", "preset": "plan", "value": ["plan": ["question": ["problem": "Solve 2x + 3 = 11"], "size": "Small steps"]],
                       "echo": "Solve 2x + 3 = 11"]),
            row("a6", "agent", Self.step1, 14),
            row("e4", "user", "[yui] step-solve-2x-3-11-0928-1 choose", 15, kind: "event",
                meta: ["id": "step-solve-2x-3-11-0928-1", "preset": "choose", "value": ["choice": "7", "correct": false], "echo": "7"]),
            row("a7", "agent", Self.step2, 16),
            row("e5", "user", "[yui] step-solve-2x-3-11-0928-2 choose", 17, kind: "event",
                meta: ["id": "step-solve-2x-3-11-0928-2", "preset": "choose", "value": ["choice": "4", "correct": true], "echo": "4"]),
            row("a8", "agent", Self.problemDone, 18),
        ]
    }

    func testLight() throws { try run("light") }
    func testDark() throws { try run("dark") }

    /// The nth button of a label on the questions screen, scrolled into reach.
    private func nth(_ app: XCUIApplication, _ label: String, _ n: Int) -> XCUIElement {
        let all = app.buttons.matching(NSPredicate(format: "label == %@", label))
        for _ in 0..<8 where !(all.count > n && all.element(boundBy: n).isHittable) { app.swipeUp() }
        return all.element(boundBy: n)
    }

    private func sendQuestions(_ app: XCUIApplication, _ label: String) {
        let send = app.buttons["stage-send"]
        for _ in 0..<8 where !(send.exists && send.isHittable) { app.swipeUp() }
        XCTAssertTrue(send.isEnabled, "Send (\(label)) is off with every question answered")
        XCTAssertEqual(send.label, label)
        send.tap()
    }

    /// His pages after everything: what he keeps current by patches.
    private func checkPages(_ app: XCUIApplication, _ when: String) {
        app.goToScreen(2)
        let studying = app.descendants(matching: .any)["stage-screen-2"]
        XCTAssertTrue(studying.staticTexts["Photosynthesis, 5 cards, World capitals, 8 cards"].waitForExistence(timeout: 8)
                      || text(app, "Photosynthesis, 5 cards", timeout: 3), "What you're studying lost the new deck \(when)")
        shot("p2-studying-\(when)")
        app.goToScreen(3)
        XCTAssertTrue(text(app, "Review 1 card", timeout: 8), "Next review lost its count \(when)")
        shot("p3-next-review-\(when)")
        app.goToScreen(4)
        XCTAssertTrue(text(app, "Last quiz", timeout: 8), "Progress is gone \(when)")
        XCTAssertTrue(text(app, "1/2", timeout: 3), "Progress lost the last score \(when)")
        shot("p4-progress-\(when)")
    }

    private func run(_ look: String) throws {
        appearance = look
        let log = tmp.appending(path: "yui-quill-events-\(look).jsonl").path
        try? FileManager.default.removeItem(atPath: log)
        // One reply per relayed tap, in order: each chip, each Send, a quiz answer (quiet, three), the deck's done, a step answer.
        let replies = try write("yui-quill-replies.json", [Self.reviewOpen, Self.reviewSaved,
                                                            Self.learnOpen, Self.lesson, Self.quiet, Self.quiet, Self.quiet, Self.quizDone,
                                                            Self.problemOpen, Self.step1, Self.step2, Self.problemDone])
        var app = launch(["-yuiDemoHome", "-yuiDemoReplyFile", replies, "-yuiDemoReplyTaps", "-yuiDemoReplyAfter", "0.6", "-yuiEventLog", log])

        // Review my cards: one plan, a rating a card, one Send.
        let review = app.buttons["home-chip-review"]
        XCTAssertTrue(review.waitForExistence(timeout: 15), "no Review my cards chip on Quill's home")
        shot("1-home")
        review.tap()
        XCTAssertTrue(text(app, "8 cards due", timeout: 15) || text(app, "Review 8 cards", timeout: 5), "the review never opened")
        forward(app) { self.hittable(app, "Again", timeout: 1) }
        XCTAssertFalse(app.buttons["stage-send"].isEnabled, "Send before any rating")
        shot("2-review-cards")
        let ratings = ["Again", "Hard", "Good", "Easy", "Good", "Good", "Good", "Good"]
        // Every card carries all four buttons, so card i's is the i-th of its label.
        for (i, r) in ratings.enumerated() { nth(app, r, i).tap() }
        shot("3-review-rated")
        sendQuestions(app, "Save my review")
        XCTAssertTrue(text(app, "8 cards reviewed", timeout: 20), "the review never came back")
        let rated = events(log).compactMap { $0["plan"] as? [String: Any] }.last
        let plan = try XCTUnwrap(rated, "no {plan} event: \(events(log))")
        XCTAssertEqual(plan.count, 8, "eight ratings")
        XCTAssertEqual(plan["c-c1"] as? String, "Again")
        XCTAssertEqual(plan["c-c4"] as? String, "Easy")
        app.goToScreen(3)
        XCTAssertTrue(text(app, "Review 1 card", timeout: 8), "Next review did not patch to 1 due")
        shot("4-next-review")
        app.goToScreen(1)

        // Learn something new: one plan, the topic and questions last, one Send.
        if app.buttons["Close full screen"].exists { app.buttons["Close full screen"].tap() }
        let chip = b(app, "home-chip-learn")
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "no Learn something new chip")
        chip.tap()
        XCTAssertTrue(text(app, "learn something", timeout: 15), "Quill never answered")
        forward(app) { self.text(app, "Five minutes, then a quiz", timeout: 1) }
        XCTAssertTrue(text(app, "Five minutes, then a quiz", timeout: 5), "the learn plan never opened")
        shot("5-plan-open")
        forward(app) { self.hittable(app, "5 minutes", timeout: 1) }
        let send = app.buttons["stage-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "no one Send under the questions")
        XCTAssertEqual(send.label, "Teach me")
        XCTAssertFalse(send.isEnabled, "Send before any answer")
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3), "no topic field")
        if !field.isHittable { app.swipeUp() }
        field.tap()
        field.typeText("Photosynthesis")
        for a in ["5 minutes", "Nothing yet"] {
            let o = b(app, a)
            XCTAssertTrue(o.waitForExistence(timeout: 3), "no \(a)")
            if !o.isHittable { app.swipeUp() }
            b(app, a).tap()
        }
        shot("6-questions")
        if !send.isHittable { app.swipeUp() }
        XCTAssertTrue(send.isEnabled, "Send still off with every question answered")
        send.tap()

        // The lesson lands as a deck, a page an idea, its quiz at the end.
        XCTAssertTrue(text(app, "5 minute lesson", timeout: 20), "the lesson never landed")
        forward(app) { self.text(app, "Plants make food from light", timeout: 1) }
        XCTAssertTrue(text(app, "Plants make food from light", timeout: 3), "the lesson is not a deck")
        sleep(1)
        shot("7-lesson")
        let learn = events(log).compactMap { $0["plan"] as? [String: Any] }.last
        let lp = try XCTUnwrap(learn, "no {plan} event: \(events(log))")
        XCTAssertEqual((lp["topic"] as? [String: Any])?["topic"] as? String, "Photosynthesis")
        XCTAssertEqual(lp["time"] as? String, "5 minutes")
        forward(app, max: 12) { self.hittable(app, "Carbon dioxide", timeout: 1) }
        XCTAssertTrue(hittable(app, "Carbon dioxide", timeout: 5), "the quiz never showed")
        for a in ["Carbon dioxide", "Chloroplasts", "Sugar and oxygen"] {
            XCTAssertTrue(hittable(app, a, timeout: 5), "no quiz answer \(a)")
            b(app, a).tap()
        }
        shot("8-quiz")
        sendQuestions(app, "Send")
        XCTAssertTrue(text(app, "2 of 3", timeout: 15) || text(app, "in your review", timeout: 5), "the score never came back")
        shot("9-score")
        let sent = events(log)
        XCTAssertEqual(sent.filter { ($0["id"] as? String ?? "").hasPrefix("quiz-photosynthesis") }.count, 3, "three quiz answers")
        let done = sent.first { $0["done"] as? Bool == true }
        XCTAssertEqual(done?["score"] as? Int, 3, "the deck's done carries the score (\(sent))")
        XCTAssertEqual(done?["of"] as? Int, 3)

        // Walk me through a problem: type it, small steps, then a step a page.
        if app.buttons["Close full screen"].exists { app.buttons["Close full screen"].tap() }
        b(app, "home-chip-problem").tap()
        XCTAssertTrue(text(app, "One step at a time", timeout: 20),
                      "the problem plan never opened (events: \(events(log).compactMap { $0["id"] })): \(app.staticTexts.allElementsBoundByIndex.map { $0.label })")
        forward(app) { self.hittable(app, "Small steps", timeout: 1) }
        let pf = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(pf.waitForExistence(timeout: 3), "no problem field")
        pf.tap()
        pf.typeText("Solve 2x + 3 = 11")
        b(app, "Small steps").tap()
        shot("10-problem-plan")
        sendQuestions(app, "Start")
        XCTAssertTrue(text(app, "in 2 steps", timeout: 20), "the steps never came")
        forward(app) { app.buttons["stage-send"].exists }
        XCTAssertTrue(text(app, "What is 11 - 3?", timeout: 5), "step 1 never asked")
        XCTAssertTrue(hittable(app, "8", timeout: 5), "no answers under step 1")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Divide by 2")).firstMatch.exists,
                       "step 2 showed before step 1 was answered")
        shot("11-step-1")
        b(app, "7").tap()
        sendQuestions(app, "Send")
        XCTAssertTrue(text(app, "Not quite", timeout: 20), "step 2 never came")
        forward(app) { app.buttons["stage-send"].exists }
        XCTAssertTrue(text(app, "So x is?", timeout: 5), "step 2 never asked")
        shot("12-step-2")
        b(app, "4").tap()
        sendQuestions(app, "Send")
        XCTAssertTrue(text(app, "Solved", timeout: 20), "the problem never finished")
        shot("13-solved")

        // His pages, patched all the way: the new deck, the due count, the last score.
        if app.buttons["Close full screen"].exists { app.buttons["Close full screen"].tap() }
        checkPages(app, "live")

        // Killed: the thread comes back from the server's rows.
        app.terminate()
        let thread = try write("yui-quill-rows.json", rows(Self.homeRow))
        app = launch(["-yuiDemoHome", "-yuiThreadRows", thread, "-yuiEventLog", log])
        XCTAssertTrue(app.buttons["home-chip-learn"].waitForExistence(timeout: 15), "no home after the relaunch")
        XCTAssertTrue(text(app, "Nothing waiting on you"), "his pages' buttons read as waiting on you")
        checkPages(app, "relaunched")

        // Five trips to another agent and back (the 0.5.0 crash path): up, and his pages kept.
        // (The drawer closing on another screen than 1 takes the person to the record: that is by design, so start from 1.)
        for i in 1...5 {
            if app.buttons["Close full screen"].exists { app.buttons["Close full screen"].tap() }
            app.goToScreen(1)
            XCTAssertTrue(app.pickAgent("Yui"), "could not switch to Yui (trip \(i))")
            XCTAssertTrue(app.pickAgent("Quill"), "could not switch back to Quill (trip \(i))")
            XCTAssertEqual(app.state, .runningForeground, "the app died on trip \(i)")
        }
        let who = app.talkingTo()
        XCTAssertTrue(who.contains("Quill"), "not back on Quill: \(who)")
        XCTAssertTrue(app.descendants(matching: .any)["stage-first"].exists || app.screenCount > 1,
                      "no stage and no screens after the switches: \(app.screenCount) screens, \(app.buttons.allElementsBoundByIndex.map { $0.identifier })")
        checkPages(app, "switched")
    }

    /// Quill's home row, as yui-agents writes it (runtime/profiles/quill/home.yui): the starter deck, before any tool ran.
    static let homeRow = #"""
```yui
menu shortcut@next "What's due?" say="What should I review next?"
menu shortcut@problem "Walk me through a problem" say="Walk me through a problem"
menu shortcut@learn "Learn something new" say="Teach me something new"
menu shortcut@review "Review my cards" say="Review my cards"
>2
card@studying "World capitals" "8 cards. 8 due today." sub="Geography" cta="Review now"
list@decks title="Your decks" "World capitals, 8 cards"
card@learn-new "Learn something new" "A topic, how long you have, what you know. A short lesson, then a quiz." cta="Learn a topic"
card@walk "Stuck on a problem?" "I'll break it into steps. You answer each one before the next." cta="Walk me through it"
save studying
>3
stat@due 8 "Cards due today" sub="World capitals"
card@review-start "Review 8 cards" "Think of the answer, then tap again, hard, good or easy." cta="Start review"
save next review
>4
stat@streak 0 "Day streak" sub="Review today to start one"
chart@studied bar "Cards reviewed" x=Mon|Tue|Wed|Thu|Fri|Sat|Sun y=0|0|0|0|0|0|0
stat@learned 0 "Cards learned" sub="of 8 cards, box 4 or higher"
stat@last-quiz "None" "Last quiz" sub="Finish a lesson's quiz"
save progress
```
"""#
}
