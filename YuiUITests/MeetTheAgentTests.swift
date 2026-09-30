import XCTest

/// Meet the agent (YUI-167). Chris on build 244: "when I got to his screen for the first
/// time, all it showed me was a blank screen ... I like where you have the agent picker in
/// the main. I think we can get rid of the agent picker from the left side bar." The first
/// open of an agent plays its hello on the stage; after that the thread opens as always.
/// The top pill is the one picker, each row with the agent's tagline; the drawer has none.
/// About says what the agent does, and its three starters send. Demo account, the crew as
/// yui_native_provision makes it, no network. `YUI_SHOTS=<dir>` saves screenshots.
@MainActor
final class MeetTheAgentTests: XCTestCase {
    func testLight() throws { try run("light") }
    func testDark() throws { try run("dark") }

    private var tag = ""
    private let app = XCUIApplication()

    private func text(_ s: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
    }

    private func launch(_ extra: [String]) {
        app.terminate()
        // A starter sent from About gets this answer.
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoFirstLaunch", "-yuiStageFirst", "YES", "-appearance", tag,
                               "-yuiDemoReply", "say \"Here is your week.\""] + extra
        app.launch()
    }

    private func run(_ look: String) throws {
        tag = look
        let greeting = app.descendants(matching: .any)["stage-greeting"]

        // 1. Arnold, opened for the first time: his hello plays on the stage, not the blank greeting.
        launch(["-yuiAgent", "arnold"])
        XCTAssertTrue(text("Arnold here.").waitForExistence(timeout: 20), "Arnold's hello did not play on the stage")
        XCTAssertTrue(app.descendants(matching: .any)["stage-first"].exists, "the hello is not on the stage")
        XCTAssertFalse(greeting.exists, "the blank greeting shows on a first open")
        sleep(2)
        shot("01-arnold-hello")
        // Its questions come after, one Send.
        let next = app.buttons["stage-next"]
        if next.waitForExistence(timeout: 3) { next.tap() }
        XCTAssertTrue(text("How many days a week?").waitForExistence(timeout: 8), "the hello's questions never came")
        sleep(1)
        shot("02-arnold-questions")

        // 2. The drawer's picker is the one picker: every agent, each with what it does under its name.
        app.buttons["stage-menu"].tap()
        app.buttons["drawer-agent-bar"].tap()
        XCTAssertTrue(text("Eat better without counting everything").waitForExistence(timeout: 5), "no tagline under Basil")
        sleep(1)
        shot("03-picker-taglines")
        let basil = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Basil")).firstMatch
        XCTAssertTrue(basil.exists, "no Basil in the picker")
        basil.tap()
        // Basil is new too: his hello plays.
        XCTAssertTrue(text("I'm Basil.").waitForExistence(timeout: 10), "Basil's hello did not play on his first open")
        sleep(1)
        shot("04-basil-hello")

        // 3. Back to Arnold: seen, so the stage opens as it always does.
        XCTAssertTrue(app.pickAgent("Arnold"), "no Arnold in the picker")
        XCTAssertTrue(greeting.waitForExistence(timeout: 8), "Arnold's hello played a second time")
        sleep(1)
        shot("05-arnold-again")

        // 4. The drawer keeps the agent bar; About says what Arnold does, and a starter sends.
        app.buttons["stage-menu"].tap()
        let close = app.buttons["drawer-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the menu did not open the drawer")
        XCTAssertTrue(app.buttons["drawer-agent-bar"].exists, "the agent bar is missing from the bottom of the drawer")
        app.buttons["drawer-tab-agent"].tap()
        let tagline = app.descendants(matching: .any)["about-tagline"]
        XCTAssertTrue(tagline.waitForExistence(timeout: 5), "About has no tagline")
        XCTAssertEqual(tagline.label, "Workouts built around your week and body")
        XCTAssertTrue(app.descendants(matching: .any)["about-what"].exists, "About does not say what Arnold does")
        XCTAssertFalse(text("Yui doesn't own your agent").exists, "a native agent's About still says Yui doesn't own it")
        XCTAssertTrue(text("Runs on").exists, "Runs on is gone")
        sleep(1)
        shot("06-about")
        let can = app.buttons["about-can-0"]
        XCTAssertTrue(can.exists, "no starters on About")
        XCTAssertTrue(can.label.contains("Start today's workout"), "the first starter is wrong: \(can.label)")
        can.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'stage-you' AND label CONTAINS %@", "Start today's workout"))
                        .firstMatch.waitForExistence(timeout: 10), "the starter was not sent")
        XCTAssertTrue(text("Here is your week.").waitForExistence(timeout: 10), "Arnold never answered the starter")
        sleep(2)
        shot("07-starter-sent")
    }

    override func setUp() async throws { continueAfterFailure = false }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "meet-\(name)-\(tag).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "\(tag)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }
}
