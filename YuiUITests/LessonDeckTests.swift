import XCTest

/// A lesson is one deck (YUI-113, TestFlight feedback APSw0dsa): the shapes, the
/// formula, the chart and the stat are pictures on the deck's pages, the quiz is a
/// page, and the calculator is the last page. Demo account, no network.
/// `TEST_RUNNER_YUI_SHOTS=<dir>` saves a screenshot of every page.
final class LessonDeckTests: XCTestCase {
    static let lesson = """
    say "Compound interest in a minute. Swipe through."
    >full
    deck "Compound interest"
    page "Money that grows on itself" body="Your interest joins the pile. Next year the pile earns interest too."
    shapes
    shape circle $100 +grow
    shape arrow
    shape box "+10%" +fill tone=butter
    shape arrow
    shape blob $110 +pulse tone=mint
    page "The formula" body="P is what you put in, r the rate, t the years. A is what you end with."
    math A = P(1 + r)^t
    page "It bends upward" body="The same 10% adds more every year, because the pile keeps growing."
    chart line "$100 at 10% a year" x=Y0|Y5|Y10|Y15|Y20 y=100|161|259|418|673
    page "Twenty years later" body="You put in $100. Time did the rest."
    stat $673 "After 20 years" delta=+573 spark=100|161|259|418|673
    choose "Which lever grows the pile fastest?" "More time"|"Checking daily"|"A bigger first deposit only" answer="More time"
    page "Try it" body="Slide the start, the rate and the years."
    calc f="A = P*(1+r)^t" P=100-1000@100 r=0-0.2@0.05 t=0-20@10
    """

    private var appearance: String { ProcessInfo.processInfo.environment["YUI_APPEARANCE"] ?? "dark" }

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: dir).appending(path: "lesson-\(name)-\(appearance).png"))
    }

    func testLessonIsOneDeck() {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemo", "-appearance", appearance, "-yuiDemoReply",
                              Self.lesson.replacingOccurrences(of: "\n", with: "\\n")]
        app.launch()
        let field = app.descendants(matching: .any)["composer"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no composer")
        field.tap()
        field.typeText("Explain compound interest")
        app.buttons["Send"].tap()

        let titles = ["Money that grows on itself", "The formula", "It bends upward", "Twenty years later", nil, "Try it"]
        let first = app.staticTexts["Money that grows on itself"]
        XCTAssertTrue(first.waitForExistence(timeout: 20), "the lesson never opened as a deck")
        let next = app.buttons["Next page"]
        for (i, t) in titles.enumerated() {
            if i > 0 {
                next.tap()
                sleep(1)
            }
            if let t { XCTAssertTrue(app.staticTexts[t].waitForExistence(timeout: 5), "page \(i + 1) is not \(t)") }
            else { XCTAssertTrue(app.buttons["More time"].waitForExistence(timeout: 5), "page \(i + 1) is not the quiz") }
            sleep(1)
            shot(String(format: "%02d", i + 1))
        }
        let slider = app.sliders.firstMatch
        XCTAssertTrue(slider.exists, "the last page has no calculator")
        // A drag on a slider moves the slider, not the page.
        slider.adjust(toNormalizedSliderPosition: 0.8)
        sleep(1)
        XCTAssertTrue(app.staticTexts["Try it"].exists, "dragging a slider turned the page")
        shot("07-slid")
        XCTAssertFalse(next.isEnabled, "there is a page after the calculator: the deck is not six pages")
    }
}
