import XCTest

/// Basil counts calories by date (t_7af94763, TestFlight feedback AKcB7F2gLtI6WGAM3uata6g): a new day opens at 0 kcal,
/// yesterday's 390 does not carry over, and page 5 draws calories over time. The reply is runtime/src/mealplan.ts's
/// Today patch and trendScreen on a Sunday with nothing logged yet, verbatim in shape. Demo account, no network.
/// `YUI_SHOTS=<dir>` saves screenshots, light and dark.
final class BasilCaloriesByDateTests: XCTestCase {
    static let reply = #"""
New day, fresh count.
```yui
>5 clear
>5
stat@trend-avg 1,980kcal "Daily average" sub="Over 6 logged days of the last 30. Goal 2,100."
chart@trend-week bar "Calories, last 7 days" x=Mon|Tue|Wed|Thu|Fri|Sat|Sun y=2050|1890|2210|1760|2100|390|0 y2=2100|2100|2100|2100|2100|2100|2100 names=Eaten|Goal unit=kcal
chart@trend-month area "Calories, last 30 days" x=5|6|7|8|9|10|11|12|13|14|15|16|17|18|19|20|21|22|23|24|25|26|27|28|29|30|1|2|3|4 y=0|0|0|0|0|0|0|0|0|0|0|0|0|0|0|0|0|0|0|0|1900|2000|2050|1890|2210|1760|2100|390|0|0 unit=kcal
save trend
>2 clear
>2
stat@kcal 0kcal "Calories today" sub="of 2,100. Log a meal to start."
chart@macros bar "Macros vs goal" x=Protein|Carbs|Fat y=0|0|0 y2=140|210|70 names=Today|Goal unit=g
card@next-meal "No plan yet" "Tell me what you like and I'll plan your week." cta="Plan my meals"
save today
```
"""#

    private func run(_ appearance: String) throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "yui-basil-by-date-replies.json")
        try JSONSerialization.data(withJSONObject: [Self.reply]).write(to: url)
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoHome", "-yuiAgent", "basil", "-appearance", appearance,
                               "-yuiDemoReplyFile", url.path, "-yuiDemoReplyAfter", "0.6"]
        app.launch()
        let type = app.buttons["stage-type"]
        XCTAssertTrue(type.waitForExistence(timeout: 20), "no T on the stage")
        type.tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "T did not open the field")
        field.typeText("what did I eat today")
        app.buttons["stage-send-text"].tap()

        let today = app.descendants(matching: .any)["stage-screen-2"]
        XCTAssertTrue(today.staticTexts["Macros vs goal"].waitForExistence(timeout: 20), "Today was never drawn")
        waitScreen(app, 2, "the reply did not end on Today")
        XCTAssertTrue(app.staticTexts["Calories today"].exists, "no Calories today")
        shot("today-\(appearance)")
        app.goToScreen(5)
        XCTAssertTrue(app.descendants(matching: .any)["stage-screen-5"].staticTexts["Daily average"].waitForExistence(timeout: 10), "no Calories over time page")
        shot("trend-\(appearance)")
    }

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "basil-by-date-\(name).png"))
    }

    func testByDateLight() throws { try run("light") }
    func testByDateDark() throws { try run("dark") }
}
