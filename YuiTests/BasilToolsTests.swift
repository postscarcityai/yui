import XCTest
import YuiLines
@testable import Yui

/// Basil's tools in the app (YUI-183): the grocery list's ticks kept on the phone
/// (UserDefaults per agent and list, the real path a relaunch reads; Chris, Sep 28:
/// the 0.5.0 crash hid behind the demo account's memory), the list shared as plain
/// words by aisle, and his pages after a plan lands. No demo store here.
@MainActor
final class BasilToolsTests: XCTestCase {
    /// The runtime's answer to Plan my meals, verbatim (runtime/src/mealplan.ts planBody).
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

    /// The runtime's answer to the plan's Send, verbatim (3 days, 3 meals, chicken, no nuts): the week as a deck,
    /// Today patched, This week and Groceries drawn again.
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

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "yui.tests.ticks")
        defaults.removePersistentDomain(forName: "yui.tests.ticks")
    }

    private func thread() -> ChatStore {
        let at = ISO8601DateFormatter().string(from: .now)
        let store = ChatStore()
        store.load([
            ThreadRow(id: "home-basil", sender: "agent", body: AgentStore.demoHome["basil"]!, kind: "text",
                      meta: .object(["native": .string("home")]), createdAt: at),
            ThreadRow(id: "u1", sender: "user", body: "Plan my meals", kind: "text", meta: nil, createdAt: at),
            ThreadRow(id: "a1", sender: "agent", body: Self.plan, kind: "text", meta: nil, createdAt: at),
            ThreadRow(id: "e1", sender: "user", body: "[yui] mealplan plan", kind: "event",
                      meta: .object(["id": .string("mealplan"), "preset": .string("plan"),
                                     "value": .object(["plan": .object(["days": .string("3 days")])]), "echo": .string("3 days")]),
                      createdAt: at),
            ThreadRow(id: "a2", sender: "agent", body: Self.planned, kind: "text", meta: nil, createdAt: at),
        ])
        return store
    }

    private func page(_ store: ChatStore, _ n: Int) -> [YLComponent] {
        store.onPage(n).flatMap { $0.yl?.onPage(n, style: [:]) ?? [] }
    }

    func testATickIsKeptPerAgentAndListAndComesBackOnARelaunch() {
        let items = ["Spinach", "Berries", "Avocado, 1"]
        let ticks = ListTicks(defaults: defaults)
        ticks.set("basil-1", "aisle-produce", item: "Spinach", on: true)
        ticks.set("basil-1", "aisle-produce", item: "Avocado, 1", on: true)
        XCTAssertEqual(ticks.ticked("basil-1", "aisle-produce", items: items), ["Spinach", "Avocado, 1"])
        // Another agent's list of the same name, and another list, start clean.
        XCTAssertEqual(ticks.ticked("penny-1", "aisle-produce", items: items), [])
        XCTAssertEqual(ticks.ticked("basil-1", "aisle-pantry", items: ["Spinach"]), [])
        // A relaunch: nothing in memory, only UserDefaults.
        let again = ListTicks(defaults: defaults)
        XCTAssertEqual(again.ticked("basil-1", "aisle-produce", items: items), ["Spinach", "Avocado, 1"])
        again.set("basil-1", "aisle-produce", item: "Spinach", on: false)
        XCTAssertEqual(ListTicks(defaults: defaults).ticked("basil-1", "aisle-produce", items: items), ["Avocado, 1"])
    }

    func testTicksFollowTheWordsNotThePlace() {
        let ticks = ListTicks(defaults: defaults)
        ticks.set("b", "aisle-produce", item: "Berries", on: true)
        // A patch puts an item in front: Berries is still the ticked one.
        XCTAssertEqual(ticks.ticked("b", "aisle-produce", items: ["Kale", "Spinach", "Berries"]), ["Berries"])
    }

    func testARedrawWithoutTheItemDropsItsTick() {
        let ticks = ListTicks(defaults: defaults)
        ticks.set("b", "aisle-produce", item: "Spinach", on: true)
        ticks.set("b", "aisle-produce", item: "Berries", on: true)
        // Reading never forgets (an old copy up the chat may be missing an item).
        XCTAssertEqual(ticks.ticked("b", "aisle-produce", items: ["Berries"]), ["Berries"])
        XCTAssertEqual(ticks.ticked("b", "aisle-produce", items: ["Spinach", "Berries"]), ["Spinach", "Berries"])
        // The runtime drew the page again with Spinach got and gone: its tick goes for good,
        // so Spinach added back later comes back unticked.
        ticks.prune("b", "aisle-produce", items: ["Berries"])
        XCTAssertEqual(ListTicks(defaults: defaults).ticked("b", "aisle-produce", items: ["Spinach", "Berries"]), ["Berries"])
        ticks.prune("b", "aisle-produce", items: [])
        XCTAssertNil(defaults.object(forKey: ListTicks.key("b", "aisle-produce")), "an empty list leaves nothing behind")
    }

    func testOnlyNamedListsWithAnAgentAreKept() {
        XCTAssertTrue(ListTicks.keeps("basil-1", "aisle-produce"))
        XCTAssertFalse(ListTicks.keeps("basil-1", "n3"), "n3 is only its place in one reply")
        XCTAssertFalse(ListTicks.keeps("", "aisle-produce"))
        let ticks = ListTicks(defaults: defaults)
        ticks.set("basil-1", "n3", item: "Milk", on: true)
        XCTAssertEqual(ticks.ticked("basil-1", "n3", items: ["Milk"]), [])
    }

    func testAPlanLandsOnHisPagesAndNothingWaitsOnYou() throws {
        let store = thread()
        XCTAssertEqual(store.screens, [1, 2, 3, 4, 5])
        // Today: patched in place, the next planned meal with I ate it.
        let today = page(store, 2)
        XCTAssertEqual(today.map(\.ylID), ["kcal", "macros", "next-meal", "eaten"])
        XCTAssertEqual(today.first { $0.ylID == "next-meal" }?.string("cta"), "I ate it")
        // This week: a card a day, each meal a swap, then Plan again.
        let week = page(store, 3)
        XCTAssertEqual(week.map(\.ylID), ["wk-20260928", "wk-20260929", "wk-20260930", "week-plan"])
        XCTAssertEqual(week[0].strings("options"), ["Breakfast burrito", "Chicken burrito bowl", "Chicken stir-fry"])
        // Groceries: a list per aisle, from the plan.
        let groceries = page(store, 4)
        XCTAssertEqual(groceries.filter { $0.preset == "list" }.map(\.ylID),
                       ["aisle-produce", "aisle-meat-and-fish", "aisle-dairy-and-eggs", "aisle-bakery", "aisle-pantry"])
        // The week's swap buttons and Today's picker are tools on standing pages, not asks.
        XCTAssertEqual(store.awaitingYou.map(\.ask.ylID), [], "a redrawn page's pickers read as waiting on you")
        XCTAssertEqual(store.page, 1, "loading the thread moved the person")
    }

    func testTheGroceryListSharesByAisleWithTicksLeftOff() throws {
        let store = thread()
        let ticks = ListTicks(defaults: defaults)
        ticks.set("basil-1", "aisle-produce", item: "Spinach", on: true)
        ticks.set("basil-1", "aisle-bakery", item: "Flour tortillas, 2", on: true)
        ticks.set("basil-1", "aisle-bakery", item: "Whole wheat bread, 3 slices", on: true)
        let groceries = page(store, 4)
        let sections = ChecklistText.sections(groceries, agent: "basil-1", ticks: ticks)
        XCTAssertEqual(sections.map(\.title), ["Produce", "Meat and fish", "Dairy and eggs", "Bakery", "Pantry"])
        XCTAssertEqual(sections[0].items.first, "Berries", "a ticked item went out")
        let text = ChecklistText.text(title: groceries.first { $0.preset == "stat" }?.string("label"), sections)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(Array(lines.prefix(4)), ["Grocery list", "", "Produce", "- Berries"])
        XCTAssertTrue(lines.contains("Meat and fish"))
        XCTAssertTrue(lines.contains("- Olive oil, 1 tbsp + 1 tsp"))
        XCTAssertFalse(lines.contains("Bakery"), "an aisle with everything got still has a header")
        XCTAssertFalse(text.contains("Spinach"))
        // A page with one checklist (Arnold's sets, Penny's today) has no share.
        XCTAssertEqual(ChecklistText.sections(YLScreen(#"list@sets title="Upper" "Bench 3x8" +check"#).components,
                                              agent: "a", ticks: ticks), [])
    }

    func testTheWeekPlaysADayAPageAndASwapGoesAtOnce() {
        let yl = YLScreen(Self.planned.components(separatedBy: "```yui\n")[1].components(separatedBy: "\n```")[0])
        let r = StageChunks.of(yl, scope: "a2")
        XCTAssertEqual(r.chunks.map { $0.line ?? $0.pic?.ylID ?? "" }, ["3 days planned", "swap-20260928", "swap-20260929", "swap-20260930"])
        XCTAssertTrue(r.questions.isEmpty, "the days wait for one Send at the end, so a swap never goes")
        // A lesson's quiz (no title) still waits for the end.
        let quiz = StageChunks.of(YLScreen("""
        deck@lesson-x "Capitals" +full
        page "France" body="Paris."
        choose@quiz-x-1 "Capital of France?" Paris|Lyon answer=Paris
        end
        """), scope: "q")
        XCTAssertEqual(quiz.questions.map(\.c.ylID), ["quiz-x-1"])
    }
}
