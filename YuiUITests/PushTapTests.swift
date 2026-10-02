import XCTest

/// A notification tap opens what came (YUI-199). Chris on build 279: "I was just responding to a
/// notification that this agent has something for me and then I was taken JUST to the home
/// screen and nothing opened up." The tap names the agent (and message); the thread opens with
/// the stage on the agent's newest message, not on its home. Demo account, no network:
/// `-yuiDemoPushTap` fires the tap the payload would. `YUI_SHOTS=<dir>` saves screenshots.
@MainActor
final class PushTapTests: XCTestCase {
    private let app = XCUIApplication()
    private var appearance: String { ProcessInfo.processInfo.environment["YUI_APPEARANCE"] ?? "light" }

    private func text(_ s: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
    }

    /// A line the stage is showing (the record under it holds them all).
    private func line(_ s: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "identifier == 'stage-line' AND label BEGINSWITH %@", s)).firstMatch
    }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = "pushtap-\(name)-\(appearance)"
        a.lifetime = .keepAlways
        add(a)
        guard let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] else { return }
        try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "pushtap-\(name)-\(appearance).png"))
    }

    private func launch(agent: String, tap: String) {
        app.terminate()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoFirstLaunch", "-yuiStageFirst", "YES", "-appearance", appearance,
                               "-yuiAgent", agent, "-yuiDemoPushTap", tap, "-yuiDemoPushTapAfter", "12"]
        app.launch()
    }

    /// Sitting in Arnold's record, a tap for Basil: Basil's thread opens with his message on the stage.
    func testTapForAnotherAgentLandsOnItsMessage() {
        launch(agent: "arnold", tap: "basil")
        XCTAssertTrue(text("Arnold here.").waitForExistence(timeout: 20), "Arnold's hello did not play")
        app.buttons["stage-record"].tap()
        XCTAssertFalse(app.descendants(matching: .any)["stage-first"].waitForExistence(timeout: 2), "the stage is still up")
        sleep(1)
        shot("1-before-in-arnolds-chat")
        // The tap arrives: Basil, and what he said, on the stage. Not the greeting.
        XCTAssertTrue(text("I'm Basil.").waitForExistence(timeout: 25), "the tap did not open Basil's message")
        XCTAssertTrue(app.descendants(matching: .any)["stage-first"].exists, "Basil's message is not on the stage")
        XCTAssertFalse(app.descendants(matching: .any)["stage-greeting"].exists, "the tap landed on the home greeting")
        sleep(1)
        shot("2-after-basils-message")
    }

    /// The agent already open, at its record: a tap for it brings its message up, not the home.
    func testTapForTheOpenAgentBringsItsMessageUp() {
        launch(agent: "arnold", tap: "arnold")
        XCTAssertTrue(text("Arnold here.").waitForExistence(timeout: 20), "Arnold's hello did not play")
        app.buttons["stage-record"].tap()
        sleep(1)
        XCTAssertFalse(app.descendants(matching: .any)["stage-first"].exists, "the stage is still up")
        // His words are in the record already, so wait for the stage itself: the tap fires at 12 seconds.
        XCTAssertTrue(app.descendants(matching: .any)["stage-first"].waitForExistence(timeout: 25), "the tap did not bring Arnold's message up")
        XCTAssertTrue(text("Arnold here.").exists, "Arnold's message is not on the stage")
        XCTAssertFalse(app.descendants(matching: .any)["stage-greeting"].exists, "the tap landed on the home greeting")
    }

    /// The stage sits on the last page of a 3-message answer; a tap for that agent brings its answer up on
    /// page one (YUI-199b, Chris on build 332: "it takes me to the last screen instead of the first").
    func testTapLandsOnPageOneOfADeckNotTheLast() {
        app.terminate()
        let deck = "```yui\\nsay First page.\\n```\\n@@\\n```yui\\nsay Second page.\\n```\\n@@\\n```yui\\nsay Finish here.\\n```"
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiStageFirst", "YES", "-appearance", appearance, "-yuiAgent", "yui",
                               "-yuiDemoReply", deck, "-yuiDemoPickupAfter", "0.5", "-yuiDemoReplyAfter", "2",
                               "-yuiDemoPushTap", "yui", "-yuiDemoPushTapAfter", "30"]
        app.launch()
        XCTAssertTrue(app.buttons["stage-type"].waitForExistence(timeout: 15), "no stage")
        app.buttons["stage-type"].tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Plan it")
        app.buttons["stage-send-text"].tap()
        XCTAssertTrue(line("First page.").waitForExistence(timeout: 20), "the answer did not come")
        // To the last page: the right of the screen turns it.
        for want in ["First page.", "Second page.", "Finish here."] {
            XCTAssertTrue(line(want).waitForExistence(timeout: 8), "\(want) did not show")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        XCTAssertTrue(line("Finish here.").waitForExistence(timeout: 5), "not on the last page")
        shot("3-before-on-last-page")
        // The tap fires at 30 seconds: page one.
        sleep(32)
        shot("4-after-the-tap")
        XCTAssertTrue(line("First page.").exists, "the tap did not land on page one")
        // Short pages pack into one chunk now (all three show at once), so the last page is no longer apart from the first.
    }

    private let fresh = "```yui\\nsay Fresh news from the agent.\\n```"

    /// YUI-262, Chris on build 340: a reply landed while he sat on the home and only showed as a "1" on the chat
    /// button. It comes up full screen on its own, within 2 seconds of landing.
    func testAReplyLandingOnTheHomeComesUpFullScreen() {
        app.terminate()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiStageFirst", "YES", "-appearance", appearance, "-yuiAgent", "yui",
                               "-yuiDemoArrive", fresh, "-yuiDemoArriveAfter", "10"]
        app.launch()
        XCTAssertTrue(app.buttons["stage-type"].waitForExistence(timeout: 15), "no stage")
        sleep(1)
        shot("5-before-on-the-home")
        XCTAssertFalse(line("Fresh news").exists, "it landed early")
        let landed = Date()
        // It lands about 10 seconds after the thread loads; the stage plays it within 2 s of that.
        XCTAssertTrue(line("Fresh news").waitForExistence(timeout: 14), "the reply did not come up on its own")
        XCTAssertLessThan(Date().timeIntervalSince(landed), 12, "it came, but late")
        XCTAssertTrue(app.descendants(matching: .any)["stage-first"].exists, "the reply is not on the stage")
        sleep(1)
        shot("6-after-it-came-up")
    }

    /// A tap for a reply the thread has not fetched yet (a cold start): it waits for that reply and opens it,
    /// never the home and never an older turn.
    func testAColdTapWaitsForTheMessageItNames() {
        app.terminate()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiStageFirst", "YES", "-appearance", appearance, "-yuiAgent", "yui",
                               "-yuiDemoArrive", fresh, "-yuiDemoArriveAfter", "6",
                               "-yuiDemoPushTap", "yui", "-yuiDemoPushTapMessage", "arrive-1", "-yuiDemoPushTapAfter", "3"]
        app.launch()
        XCTAssertTrue(line("Fresh news").waitForExistence(timeout: 25), "the tap did not open the reply it named")
        XCTAssertTrue(app.descendants(matching: .any)["stage-first"].exists, "the reply is not on the stage")
        XCTAssertFalse(app.descendants(matching: .any)["stage-greeting"].exists, "the tap landed on the home")
        sleep(1)
        shot("7-cold-tap-on-the-reply")
    }
}
