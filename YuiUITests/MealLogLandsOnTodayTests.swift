import XCTest

/// After a meal is logged by words, Basil lands on that meal's calories, then Today's macros, not the grocery
/// list (YUI-183b, TestFlight feedback AGqPB6bF7ilVsfoHedSTYao). The reply is runtime/src/mealplan.ts's
/// screenLines for a Basil whose pages were never drawn, verbatim: the other pages are drawn first, Today last,
/// so Today is the page on show. Demo account, no network. `TEST_RUNNER_YUI_SHOTS=<dir>` saves screenshots.
final class MealLogLandsOnTodayTests: XCTestCase {
    static let reply = #"""
Logged: scrambled eggs and toast, about 420 kcal, 24 g protein.
```yui
>3 clear
>3
card@week-plan "This week's meals" "Tell me what you like and I'll plan your week, with a grocery list." cta="Plan my meals"
save this week
>4 clear
>4
stat@groc-left "6 to get" "Grocery list" sub="Plan your meals and this fills in"
list@aisle-produce title="Produce" "Spinach"|"Berries" +check
list@aisle-meat-and-fish title="Meat and fish" "Chicken thighs" +check
list@aisle-dairy-and-eggs title="Dairy and eggs" "Greek yogurt"|"Eggs" +check
list@aisle-pantry title="Pantry" "Rice" +check
card@groc-add "Need something else?" "Say it or type it, like: add oat milk to my groceries." cta="Add to the list"
save groceries
>2 clear
>2
stat@kcal 0kcal "Calories today" sub="of 2,100. Log a meal to start."
chart@macros bar "Macros vs goal" x=Protein|Carbs|Fat y=0|0|0 y2=140|210|70 names=Today|Goal unit=g
card@next-meal "No plan yet" "Tell me what you like and I'll plan your week." cta="Plan my meals"
choose@eaten "Tap a meal to fix it" "Log a meal" body="Nothing logged yet today."
save today
```
"""#

    func testMealLogLandsOnToday() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "yui-meal-log-replies.json")
        try JSONSerialization.data(withJSONObject: [Self.reply]).write(to: url)
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoHome", "-yuiAgent", "basil", "-appearance", "dark",
                               "-yuiDemoReplyFile", url.path, "-yuiDemoReplyAfter", "0.6"]
        app.launch()
        let type = app.buttons["stage-type"]
        XCTAssertTrue(type.waitForExistence(timeout: 20), "no T on the stage")
        type.tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "T did not open the field")
        field.typeText("I had two eggs and toast")
        app.buttons["stage-send-text"].tap()

        let today = app.descendants(matching: .any)["stage-screen-2"]
        XCTAssertTrue(today.staticTexts["Macros vs goal"].waitForExistence(timeout: 20), "Today was never drawn")
        waitScreen(app, 2, "the reply did not end on Today (Basil's grocery list came forward)")
        XCTAssertNotEqual(app.screenShown, 4, "the grocery list is showing after a meal log")
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "basil-meal-log-lands-on-today.png"))
        }
    }
}
