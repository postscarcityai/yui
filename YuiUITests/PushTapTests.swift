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
}
