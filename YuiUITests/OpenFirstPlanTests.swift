import XCTest

/// Open on Arnold's card (YUI-225): before his first plan is built it lands on the first
/// question, no close and no extra tap. After Build my week it goes to his home, as before
/// (unit test testOpenLandsOnTheFirstQuestionUntilThePlanIsBuilt: the demo thread forgets what was said
/// when the agent is switched, so the UI cannot walk back to the card). Demo account, no network. `YUI_SHOTS=<dir>` saves screenshots.
final class OpenFirstPlanTests: XCTestCase {
    func testLight() throws { try run("light") }
    func testDark() throws { try run("dark") }

    private var appearance = "light"

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "openplan-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "openplan-\(appearance)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func text(_ app: XCUIApplication, _ label: String, timeout: TimeInterval = 5) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch.waitForExistence(timeout: timeout)
    }

    private func openArnold(_ app: XCUIApplication) {
        app.goToScreen(2)
        let open = app.buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@", "Open", "Open")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10), "no Open on Arnold's card")
        shot("0-card")
        open.tap()
    }

    private func run(_ look: String) throws {
        appearance = look
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoFirstLaunch", "-yuiStageFirst", "YES", "-yuiAgent", "yui", "-appearance", look]
        app.launch()
        sleep(8)
        shot("00-launch")

        // 1. First plan not built: Open lands on the first question.
        openArnold(app)
        XCTAssertTrue(text(app, "What are we training for?", timeout: 5), "Open did not land on the first question")
        shot("1-first-question")

        XCTAssertTrue(app.buttons["Lift heavy"].exists || text(app, "Lift heavy", timeout: 2), "the answers are not on screen")
    }

    override func setUp() async throws { continueAfterFailure = false }
}
