import XCTest

/// Basil's tools, the whole way (YUI-183): Plan my meals from his home chip, one
/// full-screen plan with the questions last and one Send, the week landing as a deck
/// with his pages drawn again, a one-tap swap, the grocery list ticked (ticks say
/// nothing back) and shared. Then the app is killed and relaunched and the ticks are
/// still there, and five trips to another agent and back keep them too. Chris (Sep 28):
/// the 0.5.0 switch-agent crash hid behind the demo account's memory, so the ticks
/// live in UserDefaults and this test only passes if they come back from there.
/// Every agent reply is runtime/src/mealplan.ts's, verbatim. Demo account, no network.
/// `YUI_SHOTS=<dir>` saves screenshots.
final class BasilToolsFlowTests: XCTestCase {
    /// runtime: "Plan my meals" (planBody).
    static let plan = #"""
Let's plan your week.
```yui
plan@mealplan "Plan my meals" submit="Plan my week"
page "Your week of meals" body="I'll plan each day around your goal of 2,100 kcal and 140 g protein, from meals you can cook. Tap any meal after to swap it, and your grocery list fills in by aisle."
choose@days "How many days?" "3 days"|"5 days"|"7 days"
choose@meals "Meals a day?" "2 meals"|"3 meals"|"3 and a snack"
pick@likes "What do you like?" "Chicken"|"Fish"|"Beef"|"Veggie"|"Eggs"|"Pasta"|"Rice bowls"|"Mexican"|"Asian"|"Italian" +other
pick@avoid "Anything to leave out?" "None"|"Dairy"|"Gluten"|"Nuts"|"Shellfish"|"Fish"|"Meat"|"Pork"|"Eggs"|"Soy" +other
choose@budget "Budget?" "Keep it cheap"|"In between"|"Treat me"
choose@cook "Time to cook a meal?" "15 minutes"|"30 minutes"|"45 or more"
```
"""#
    /// runtime: the plan's Send, 3 days, 3 meals, chicken, no nuts (weekDeck + screenLines).
    static let planned = #"""
Your 3 days are planned. Tap any meal to swap it.
```yui
deck@week-deck "This week's meals"
page "3 days planned" body="About 1,781 kcal and 110 g protein a day, for a goal of 2,100. Add a snack a day to close the gap. Leaving out: nuts. 29 things on your grocery list, by aisle." points="Monday: Breakfast burrito, Chicken burrito bowl, Chicken stir-fry"|"Tuesday: Avocado toast with eggs, Teriyaki chicken rice bowl, Tofu coconut curry"|"Wednesday: Tofu scramble, Turkey hummus wrap, Spaghetti with meat sauce"
choose@swap-20260928 "Tap a meal to swap it" "Breakfast burrito"|"Chicken burrito bowl"|"Chicken stir-fry" tag="Mon" title="Monday, 1,908 kcal" body="Breakfast: Breakfast burrito, 528 kcal. Lunch: Chicken burrito bowl, 700 kcal. Dinner: Chicken stir-fry, 680 kcal"
choose@swap-20260929 "Tap a meal to swap it" "Avocado toast with eggs"|"Teriyaki chicken rice bowl"|"Tofu coconut curry" tag="Tue" title="Tuesday, 1,774 kcal" body="Breakfast: Avocado toast with eggs, 424 kcal. Lunch: Teriyaki chicken rice bowl, 650 kcal. Dinner: Tofu coconut curry, 700 kcal"
choose@swap-20260930 "Tap a meal to swap it" "Tofu scramble"|"Turkey hummus wrap"|"Spaghetti with meat sauce" tag="Wed" title="Wednesday, 1,660 kcal" body="Breakfast: Tofu scramble, 430 kcal. Lunch: Turkey hummus wrap, 570 kcal. Dinner: Spaghetti with meat sauce, 660 kcal"
end
~kcal 0kcal "Calories today" sub="of 2,100. Log a meal to start."
~macros bar "Macros vs goal" x=Protein|Carbs|Fat y=0|0|0 y2=140|210|70 names=Today|Goal unit=g
~next-meal "Up next: Lunch" "Chicken burrito bowl. 700 kcal, about 25 minutes." sub="From your plan" cta="I ate it"
~eaten "Tap a meal to fix it" "Log a meal" body="Nothing logged yet today."
>3 clear
>3
choose@wk-20260928 "Tap a meal to swap it" "Breakfast burrito"|"Chicken burrito bowl"|"Chicken stir-fry" tag="Mon" title="Monday, 1,908 kcal" body="Breakfast: Breakfast burrito, 528 kcal. Lunch: Chicken burrito bowl, 700 kcal. Dinner: Chicken stir-fry, 680 kcal"
choose@wk-20260929 "Tap a meal to swap it" "Avocado toast with eggs"|"Teriyaki chicken rice bowl"|"Tofu coconut curry" tag="Tue" title="Tuesday, 1,774 kcal" body="Breakfast: Avocado toast with eggs, 424 kcal. Lunch: Teriyaki chicken rice bowl, 650 kcal. Dinner: Tofu coconut curry, 700 kcal"
choose@wk-20260930 "Tap a meal to swap it" "Tofu scramble"|"Turkey hummus wrap"|"Spaghetti with meat sauce" tag="Wed" title="Wednesday, 1,660 kcal" body="Breakfast: Tofu scramble, 430 kcal. Lunch: Turkey hummus wrap, 570 kcal. Dinner: Spaghetti with meat sauce, 660 kcal"
card@week-plan "Want a new week?" "New likes, a new budget, or just a change." cta="Plan again"
save this week
>4 clear
>4
stat@groc-left "29 to get" "Grocery list" sub="From your meal plan and what you added"
list@aisle-produce title="Produce" "Spinach"|"Berries"|"Avocado, 1"|"Stir-fry vegetables, 3 cups"|"Broccoli, 1 cup"|"Bell peppers, 1"|"Apples, 1" +check
list@aisle-meat-and-fish title="Meat and fish" "Chicken thighs"|"Chicken breasts, 2"|"Deli turkey, 4 slices"|"Ground beef, 1/4 lb" +check
list@aisle-dairy-and-eggs title="Dairy and eggs" "Greek yogurt"|"Eggs"|"Cheddar, 1/2 cup"|"Firm tofu, 1 1/2 blocks"|"Hummus, 2 tbsp"|"Parmesan, 2 tbsp" +check
list@aisle-bakery title="Bakery" "Flour tortillas, 2"|"Whole wheat bread, 3 slices" +check
list@aisle-pantry title="Pantry" "Rice"|"Black beans, 1 can"|"Salsa, 4 tbsp"|"Soy sauce, 1 tbsp"|"Olive oil, 1 tbsp + 1 tsp"|"Teriyaki sauce, 2 tbsp"|"Coconut milk, 1/2 can"|"Curry paste, 1 tbsp"|"Pasta, 1/4 box"|"Marinara, 1/2 cup" +check
card@groc-add "Need something else?" "Say it or type it, like: add oat milk to my groceries." cta="Add to the list"
save groceries
```
"""#
    /// runtime: Monday's dinner tapped on the deck (a swap), patches only.
    static let swap = #"""
Dinner is Beef tacos now, 620 kcal. Your list follows.
```yui
~swap-20260928 "Tap a meal to swap it" "Breakfast burrito"|"Chicken burrito bowl"|"Beef tacos" tag="Mon" title="Monday, 1,848 kcal" body="Breakfast: Breakfast burrito, 528 kcal. Lunch: Chicken burrito bowl, 700 kcal. Dinner: Beef tacos, 620 kcal"
~kcal 0kcal "Calories today" sub="of 2,100. Log a meal to start."
~macros bar "Macros vs goal" x=Protein|Carbs|Fat y=0|0|0 y2=140|210|70 names=Today|Goal unit=g
~next-meal "Up next: Lunch" "Chicken burrito bowl. 700 kcal, about 25 minutes." sub="From your plan" cta="I ate it"
~eaten "Tap a meal to fix it" "Log a meal" body="Nothing logged yet today."
~wk-20260928 "Tap a meal to swap it" "Breakfast burrito"|"Chicken burrito bowl"|"Beef tacos" tag="Mon" title="Monday, 1,848 kcal" body="Breakfast: Breakfast burrito, 528 kcal. Lunch: Chicken burrito bowl, 700 kcal. Dinner: Beef tacos, 620 kcal"
~wk-20260929 "Tap a meal to swap it" "Avocado toast with eggs"|"Teriyaki chicken rice bowl"|"Tofu coconut curry" tag="Tue" title="Tuesday, 1,774 kcal" body="Breakfast: Avocado toast with eggs, 424 kcal. Lunch: Teriyaki chicken rice bowl, 650 kcal. Dinner: Tofu coconut curry, 700 kcal"
~wk-20260930 "Tap a meal to swap it" "Tofu scramble"|"Turkey hummus wrap"|"Spaghetti with meat sauce" tag="Wed" title="Wednesday, 1,660 kcal" body="Breakfast: Tofu scramble, 430 kcal. Lunch: Turkey hummus wrap, 570 kcal. Dinner: Spaghetti with meat sauce, 660 kcal"
~week-plan "Want a new week?" "New likes, a new budget, or just a change." cta="Plan again"
~groc-left "30 to get" "Grocery list" sub="From your meal plan and what you added"
~aisle-produce title="Produce" "Spinach"|"Berries"|"Avocado, 1"|"Stir-fry vegetables, 1 cup"|"Broccoli, 1 cup"|"Bell peppers, 1"|"Apples, 1"|"Lettuce, 1 cup" +check
~aisle-meat-and-fish title="Meat and fish" "Chicken thighs"|"Chicken breasts, 1"|"Deli turkey, 4 slices"|"Ground beef, 1/2 lb" +check
~aisle-dairy-and-eggs title="Dairy and eggs" "Greek yogurt"|"Eggs"|"Cheddar, 3/4 cup"|"Firm tofu, 1 1/2 blocks"|"Hummus, 2 tbsp"|"Parmesan, 2 tbsp" +check
~aisle-bakery title="Bakery" "Flour tortillas, 2"|"Whole wheat bread, 3 slices"|"Corn tortillas, 3" +check
~aisle-pantry title="Pantry" "Rice"|"Black beans, 1 can"|"Salsa, 6 tbsp"|"Olive oil, 1 tsp"|"Teriyaki sauce, 2 tbsp"|"Coconut milk, 1/2 can"|"Curry paste, 1 tbsp"|"Pasta, 1/4 box"|"Marinara, 1/2 cup" +check
~groc-add "Need something else?" "Say it or type it, like: add oat milk to my groceries." cta="Add to the list"
```
"""#

    private var appearance = "light"
    private let tmp = FileManager.default.temporaryDirectory

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "basil-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "basil-\(appearance)-\(name)"
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

    /// A grocery row on screen 4: its button, found by the item's words.
    private func item(_ app: XCUIApplication, _ words: String) -> XCUIElement {
        let page = app.descendants(matching: .any)["stage-screen-4"]
        let all = page.buttons.matching(NSPredicate(format: "label == %@", words))
        return all.allElementsBoundByIndex.first { $0.isHittable } ?? all.firstMatch
    }

    /// The stage's Next, until `there` (a reply plays a part at a time, a deck a page at a time).
    private func forward(_ app: XCUIApplication, _ there: () -> Bool) {
        for _ in 0..<6 where !there() {
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
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiAgent", "basil", "-appearance", appearance] + args
        app.launch()
        return app
    }

    /// The thread as the server hands it back on open: the home, then every row the flow wrote.
    /// The ticks are not in it (a tick is kept on the phone), so they can only come from UserDefaults.
    private func rows(_ home: String) -> [[String: Any]] {
        func row(_ id: String, _ sender: String, _ body: String, _ at: Int, kind: String = "text", meta: [String: Any]? = nil) -> [String: Any] {
            var r: [String: Any] = ["id": id, "sender": sender, "kind": kind, "body": body,
                                    "created_at": String(format: "2026-09-28T16:00:%02d+00:00", at)]
            if let meta { r["meta"] = meta }
            return r
        }
        return [
            row("home-basil", "agent", home, 0, meta: ["native": "home"]),
            row("u1", "user", "Plan my meals", 1),
            row("a1", "agent", Self.plan, 2),
            row("e1", "user", "[yui] mealplan plan", 3, kind: "event",
                meta: ["id": "mealplan", "preset": "plan", "value": ["plan": ["days": "3 days", "meals": "3 meals", "likes": ["Chicken"],
                                                                               "avoid": ["Nuts"], "budget": "In between", "cook": "30 minutes"]],
                       "echo": "3 days"]),
            row("a2", "agent", Self.planned, 4),
            row("e2", "user", "[yui] swap-20260928 choose", 5, kind: "event",
                meta: ["id": "swap-20260928", "preset": "choose", "value": ["choice": "Chicken stir-fry"], "echo": "Chicken stir-fry"]),
            row("a3", "agent", Self.swap, 6),
        ]
    }

    func testLight() throws { try run("light") }
    func testDark() throws { try run("dark") }

    private func run(_ look: String) throws {
        appearance = look
        let log = tmp.appending(path: "yui-basil-events-\(look).jsonl").path
        try? FileManager.default.removeItem(atPath: log)
        let replies = try write("yui-basil-replies.json", [Self.plan, Self.planned, Self.swap])
        var app = launch(["-yuiDemoHome", "-yuiDemoReplyFile", replies, "-yuiDemoReplyTaps", "-yuiDemoReplyAfter", "0.6",
                          "-yuiEventLog", log, "-yuiTicksReset"])

        // His home: Plan my meals is a chip.
        let chip = app.buttons["home-chip-plan"]
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "no Plan my meals chip on Basil's home")
        shot("1-home")
        chip.tap()

        // One full-screen plan: what the week aims for first, then the questions, one Send.
        XCTAssertTrue(text(app, "plan your week", timeout: 15), "Basil never answered")
        for _ in 0..<4 where !text(app, "Your week of meals", timeout: 1) {
            if app.buttons["stage-next"].exists { app.buttons["stage-next"].tap() }
        }
        XCTAssertTrue(text(app, "Your week of meals", timeout: 5), "the plan never opened")
        shot("2-plan-open")
        for _ in 0..<4 where !hittable(app, "3 days", timeout: 1) {
            if app.buttons["stage-next"].exists { app.buttons["stage-next"].tap() }
        }
        let send = app.buttons["stage-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "no one Send under the questions")
        XCTAssertEqual(send.label, "Plan my week")
        XCTAssertFalse(send.isEnabled, "Send before any answer")
        for a in ["3 days", "3 meals", "Chicken", "Mexican", "Nuts", "In between", "30 minutes"] {
            let o = b(app, a)
            XCTAssertTrue(o.waitForExistence(timeout: 3), "no \(a)")
            if !o.isHittable { app.swipeUp() }
            b(app, a).tap()
            if a == "Mexican" { shot("3-questions") }
        }
        if !send.isHittable { app.swipeUp() }
        XCTAssertTrue(send.isEnabled, "Send still off with every question answered")
        shot("4-send")
        send.tap()

        // The week lands as a deck, a page a day.
        XCTAssertTrue(text(app, "are planned", timeout: 20), "the week never landed")
        forward(app) { self.text(app, "3 days planned", timeout: 1) }
        XCTAssertTrue(text(app, "3 days planned", timeout: 3), "the week is not a deck")
        sleep(1)
        shot("5-week-deck")
        let events = { (try? String(contentsOfFile: log, encoding: .utf8)) ?? "" }
        let sent = events().split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }.compactMap { $0["plan"] as? [String: Any] }.last
        let p = try XCTUnwrap(sent, "no {plan} event: \(events())")
        XCTAssertEqual(p["days"] as? String, "3 days")
        XCTAssertEqual(p["meals"] as? String, "3 meals")
        XCTAssertEqual(Set(p["likes"] as? [String] ?? []), ["Chicken", "Mexican"])
        XCTAssertEqual(p["avoid"] as? [String], ["Nuts"])
        XCTAssertEqual(p["cook"] as? String, "30 minutes")

        // One tap swaps a meal: Monday's dinner.
        forward(app) { self.hittable(app, "Chicken stir-fry", timeout: 1) }
        XCTAssertTrue(hittable(app, "Chicken stir-fry", timeout: 3), "no swap button for Monday's dinner")
        shot("6-monday")
        b(app, "Chicken stir-fry").tap()
        XCTAssertTrue(text(app, "Beef tacos now", timeout: 10), "the swap never came back")
        XCTAssertTrue(events().contains("\"choice\":\"Chicken stir-fry\""), "the swap tap sent nothing")
        sleep(1)
        shot("6b-swapped")

        // His pages, drawn again: This week with the swap, Today with what's next.
        if app.buttons["Close full screen"].exists { app.buttons["Close full screen"].tap() }
        app.goToScreen(3)
        let week = app.descendants(matching: .any)["stage-screen-3"]
        XCTAssertTrue(week.waitForExistence(timeout: 5), "no This week page")
        XCTAssertTrue(week.buttons["Beef tacos"].waitForExistence(timeout: 5), "This week did not take the swap")
        shot("7-this-week")
        app.goToScreen(2)
        let today = app.descendants(matching: .any)["stage-screen-2"]
        XCTAssertTrue(today.staticTexts["Up next: Lunch"].waitForExistence(timeout: 5), "Today does not show the next planned meal")
        shot("8-today")

        // Groceries by aisle: two ticks, and a tick says nothing back.
        app.goToScreen(4)
        let groceries = app.descendants(matching: .any)["stage-screen-4"]
        XCTAssertTrue(groceries.staticTexts["Bakery"].waitForExistence(timeout: 5), "the grocery list was not drawn again by aisle")
        let before = events().split(separator: "\n").count
        item(app, "Spinach").tap()
        item(app, "Berries").tap()
        item(app, "Berries").tap()
        item(app, "Avocado, 1").tap()
        XCTAssertTrue(item(app, "Spinach").isSelected, "Spinach did not tick")
        XCTAssertFalse(item(app, "Berries").isSelected, "Berries did not untick")
        XCTAssertTrue(item(app, "Avocado, 1").isSelected)
        XCTAssertEqual(events().split(separator: "\n").count, before + 4, "four taps, four events")
        sleep(2)
        XCTAssertFalse(app.descendants(matching: .any)["stage-working"].exists, "a tick started a turn")
        shot("9-groceries-ticked")

        // Share: the list as words, by aisle.
        let share = groceries.buttons["page-share-4"]
        XCTAssertTrue(share.waitForExistence(timeout: 3), "no Share list on the grocery page")
        share.tap()
        let sheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 8) || app.navigationBars["UIActivityContentView"].waitForExistence(timeout: 2),
                      "Share list opened no share sheet")
        sleep(1)
        shot("10-share-sheet")
        if app.buttons["Close"].exists { app.buttons["Close"].tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap() }

        // Killed: the thread comes back from the server's rows, the ticks from the phone.
        app.terminate()
        let thread = try write("yui-basil-rows.json", rows(Self.homeRow))
        app = launch(["-yuiDemoHome", "-yuiThreadRows", thread, "-yuiEventLog", log])
        XCTAssertTrue(app.buttons["home-chip-plan"].waitForExistence(timeout: 15), "no home after the relaunch")
        XCTAssertFalse(app.descendants(matching: .any)["home-waiting"].exists, "his pages' pickers read as waiting on you")
        app.goToScreen(4)
        XCTAssertTrue(item(app, "Spinach").waitForExistence(timeout: 8), "the grocery list is gone after the relaunch")
        XCTAssertTrue(item(app, "Spinach").isSelected, "Spinach lost its tick on relaunch")
        XCTAssertTrue(item(app, "Avocado, 1").isSelected, "Avocado lost its tick on relaunch")
        XCTAssertFalse(item(app, "Berries").isSelected)
        shot("11-relaunched")

        // Five trips to another agent and back (the 0.5.0 crash path): up, and the ticks kept.
        for i in 1...5 {
            if app.buttons["Close full screen"].exists { app.buttons["Close full screen"].tap() }
            XCTAssertTrue(app.pickAgent("Yui"), "could not switch to Yui (trip \(i))")
            XCTAssertTrue(app.pickAgent("Basil"), "could not switch back to Basil (trip \(i))")
            XCTAssertEqual(app.state, .runningForeground, "the app died on trip \(i)")
        }
        let who = app.talkingTo()
        XCTAssertTrue(who.contains("Basil"), "not back on Basil: \(who)")
        app.goToScreen(4)
        XCTAssertTrue(item(app, "Spinach").waitForExistence(timeout: 8), "the grocery list is gone after the switches")
        XCTAssertTrue(item(app, "Spinach").isSelected, "Spinach lost its tick after 5 switches")
        XCTAssertTrue(item(app, "Avocado, 1").isSelected, "Avocado lost its tick after 5 switches")
        shot("12-after-switches")
    }

    /// Basil's home row, as yui-agents writes it (runtime/profiles/basil/home.yui).
    static let homeRow = #"""
```yui
menu shortcut@groceries "Grocery list" show=groceries
menu shortcut@week "This week" show="this week"
menu shortcut@log "Log a meal" say="Log a meal: "
menu shortcut@plan "Plan my meals" say="Plan my meals"
>2
stat@kcal 0kcal "Calories today" sub="of 2,100. Log a meal to start."
chart@macros bar "Macros vs goal" x=Protein|Carbs|Fat y=0|0|0 y2=140|210|70 names=Today|Goal unit=g
card@next-meal "No plan yet" "Tell me what you like and I'll plan your week." cta="Plan my meals"
choose@eaten "Tap a meal to fix it" "Log a meal" body="Nothing logged yet today."
save today
>3
card@week-plan "This week's meals" "Tell me what you like and I'll plan your week, with a grocery list." cta="Plan my meals"
save this week
>4
stat@groc-left "6 to get" "Grocery list" sub="Plan your meals and this fills in"
list@aisle-produce title="Produce" "Spinach"|"Berries" +check
list@aisle-meat-and-fish title="Meat and fish" "Chicken thighs" +check
list@aisle-dairy-and-eggs title="Dairy and eggs" "Greek yogurt"|"Eggs" +check
list@aisle-pantry title="Pantry" "Rice" +check
card@groc-add "Need something else?" "Say it or type it, like: add oat milk to my groceries." cta="Add to the list"
save groceries
```
"""#
}
