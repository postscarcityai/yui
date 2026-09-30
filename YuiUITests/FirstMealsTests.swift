import XCTest

/// A first plan in every agent, Basil second (YUI-221, PROP-4). A new person opens Basil: his hello
/// plays, the five questions come last (goal, days, meals a day, what to leave out, how long to
/// cook), Not sure and Skip beside each, one Send. The runtime answers with the week, and the week's
/// page is drawn again from it: a card for each chosen day, and only those.
/// The reply is runtime/src/mealplan.ts's (applyMealFirst + screenLines), verbatim, for
/// Eat better, Mon Wed Fri, 3 meals, no dairy, 30 minutes on Monday 2026-09-28 (mealplan.test.ts
/// "the reply lands on the week" holds the same shape). Demo account, no network.
/// `YUI_SHOTS=<dir>` saves screenshots.
final class FirstMealsTests: XCTestCase {
    static let built = #"""
Your week of meals is set: 3 days, 3 meals a day, nothing with dairy. Tap any meal to swap it.
```yui
~kcal 0kcal "Calories today" sub="of 2,100. Log a meal to start."
~macros bar "Macros vs goal" x=Protein|Carbs|Fat y=0|0|0 y2=140|210|70 names=Today|Goal unit=g
~next-meal "Up next: Lunch" "Chicken burrito bowl. 700 kcal, about 25 minutes." sub="From your plan" cta="I ate it"
~eaten "Tap a meal to fix it" "Log a meal" body="Nothing logged yet today."
>4 clear
>4
stat@groc-left "26 to get" "Grocery list" sub="From your meal plan and what you added"
list@aisle-produce title="Produce" "Spinach"|"Berries"|"Bell peppers, 1"|"Avocado, 1"|"Stir-fry vegetables, 5 cups"|"Broccoli, 1 cup"|"Blueberries, 1/2 cup" +check
list@aisle-meat-and-fish title="Meat and fish" "Chicken thighs"|"Chicken breasts, 3" +check
list@aisle-dairy-and-eggs title="Dairy and eggs" "Greek yogurt"|"Eggs"|"Firm tofu, 1 1/2 blocks"|"Oat milk, 1 cup" +check
list@aisle-bakery title="Bakery" "Whole wheat bread, 3 slices" +check
list@aisle-pantry title="Pantry" "Rice"|"Olive oil, 1 tsp + 3 tbsp"|"Black beans, 1/2 can"|"Salsa, 2 tbsp"|"Soy sauce, 3 tbsp"|"Teriyaki sauce, 2 tbsp"|"Coconut milk, 1/2 can"|"Curry paste, 1 tbsp"|"Oats, 1/2 cup"|"Chia seeds, 1 tbsp"|"Maple syrup, 1 tbsp" +check
list@aisle-frozen title="Frozen" "Frozen peas, 1/2 cup" +check
card@groc-add "Need something else?" "Say it or type it, like: add oat milk to my groceries." cta="Add to the list"
save groceries
>3 clear
>3
choose@wk-20260928 "Tap a meal to swap it" "Tofu scramble"|"Chicken burrito bowl"|"Chicken stir-fry" tag="Mon" title="Monday, 1,810 kcal" body="Breakfast: Tofu scramble, 430 kcal. Lunch: Chicken burrito bowl, 700 kcal. Dinner: Chicken stir-fry, 680 kcal"
choose@wk-20260930 "Tap a meal to swap it" "Avocado toast with eggs"|"Teriyaki chicken rice bowl"|"Tofu coconut curry" tag="Wed" title="Wednesday, 1,774 kcal" body="Breakfast: Avocado toast with eggs, 424 kcal. Lunch: Teriyaki chicken rice bowl, 650 kcal. Dinner: Tofu coconut curry, 700 kcal"
choose@wk-20261002 "Tap a meal to swap it" "Overnight oats with chia"|"Egg fried rice"|"Chicken stir-fry" tag="Fri" title="Friday, 1,742 kcal" body="Breakfast: Overnight oats with chia, 422 kcal. Lunch: Egg fried rice, 640 kcal. Dinner: Chicken stir-fry, 680 kcal"
card@week-plan "Want a new week?" "New likes, a new budget, or just a change." cta="Plan again"
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
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "firstmeals-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "firstmeals-\(appearance)-\(name)"
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
        let log = tmp.appending(path: "yui-firstmeals-events-\(look).jsonl").path
        try? FileManager.default.removeItem(atPath: log)
        let replies = tmp.appending(path: "yui-firstmeals-replies.json")
        try JSONSerialization.data(withJSONObject: [Self.built]).write(to: replies)
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoFirstLaunch", "-yuiStageFirst", "YES", "-yuiAgent", "basil", "-appearance", look,
                               "-yuiDemoReplyFile", replies.path, "-yuiDemoReplyTaps", "-yuiDemoReplyAfter", "0.6", "-yuiEventLog", log]
        app.launch()

        // 1. The first open plays his hello, not a blank screen, and the questions come after it.
        XCTAssertTrue(text(app, "I'm Basil.", timeout: 20), "Basil's hello did not play")
        XCTAssertTrue(text(app, "Five taps", timeout: 3), "the hello does not promise the five taps")
        sleep(1)
        shot("1-hello")
        for _ in 0..<4 where !text(app, "What's the goal?", timeout: 1) {
            if app.buttons["stage-next"].exists { app.buttons["stage-next"].tap() }
        }
        XCTAssertTrue(text(app, "What's the goal?", timeout: 8), "the intake's questions never came")

        // 2. One screen of questions, one Send. Not sure and Skip sit beside the real answers; Send waits for an answer.
        let send = app.buttons["stage-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "no one Send under the questions")
        XCTAssertEqual(send.label, "Plan my week")
        XCTAssertFalse(send.isEnabled, "Send before any answer")
        for a in ["Eat better", "Not sure", "Skip"] {
            XCTAssertTrue(b(app, a).waitForExistence(timeout: 3), "no \(a)")
        }
        shot("2-first-question")
        for a in ["Eat better", "Mon", "Wed", "Fri", "3", "Dairy", "30 minutes"] {
            let o = b(app, a)
            XCTAssertTrue(o.waitForExistence(timeout: 3), "no \(a)")
            if !o.isHittable { app.swipeUp() }
            b(app, a).tap()
            if a == "Dairy" { shot("3-leave-out") }
        }
        if !send.isHittable { app.swipeUp() }
        XCTAssertTrue(send.isEnabled, "Send still off with every question answered")
        shot("4-send")
        send.tap()

        // 3. Basil answers with the week, and it is what the answers asked for.
        XCTAssertTrue(text(app, "Your week of meals is set: 3 days", timeout: 20), "the week was never built")
        sleep(1)
        let events = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        let sent = events.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }.compactMap { $0["plan"] as? [String: Any] }.last
        let p = try XCTUnwrap(sent, "no {plan} event: \(events)")
        XCTAssertEqual(p["goal"] as? String, "Eat better")
        XCTAssertEqual(p["days"] as? [String], ["Mon", "Wed", "Fri"])
        XCTAssertEqual(p["meals"] as? String, "3")
        XCTAssertEqual(p["avoid"] as? [String], ["Dairy"])
        XCTAssertEqual(p["cook"] as? String, "30 minutes")

        // 4. The week is saved: its page has a card for each chosen day and none for the rest, and no dairy.
        if app.buttons["Close full screen"].exists { app.buttons["Close full screen"].tap() }
        app.goToScreen(3)
        let week = app.descendants(matching: .any)["stage-screen-3"]
        XCTAssertTrue(week.waitForExistence(timeout: 5), "no This week's meals page")
        for day in ["Monday", "Wednesday", "Friday"] {
            XCTAssertTrue(text(app, "\(day), ", timeout: 5), "no card for \(day)")
        }
        for day in ["Tuesday", "Thursday", "Saturday", "Sunday"] {
            XCTAssertFalse(text(app, "\(day), ", timeout: 1), "a card for \(day), which was not chosen")
        }
        XCTAssertTrue(text(app, "Chicken burrito bowl", timeout: 5), "the week's meals are not on the page")
        XCTAssertFalse(text(app, "Greek yogurt parfait", timeout: 1), "a dairy meal is on the week")
        shot("5-week")
    }

    override func setUp() async throws { continueAfterFailure = false }
}
