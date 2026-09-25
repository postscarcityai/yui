import XCTest

/// @mentions (YUI-44): in Alpha's thread, @ shows the person's other agents
/// (face, name, presence), typing filters, a tap lands `@Bravo `, and the
/// message goes to Bravo. Bravo's answer shows up here in Bravo's look, with
/// its thread one tap away; an offline agent says so.
///
/// Driven by supabase/tests/mention_e2e.py --sim <udid>, which makes a
/// throwaway account with three agents (Alpha and Bravo served by real Yui
/// adapters on this Mac, Cleo stopped) and hands over one FRESH refresh token
/// per launch (a spent one signs out every device):
///
///   TEST_RUNNER_YUI_RTS=<rt1>,<rt2> TEST_RUNNER_YUI_USER=<uuid> TEST_RUNNER_YUI_SHOTS=/tmp/shots \
///     xcodebuild test -scheme Yui -destination '...' -only-testing:YuiUITests/MentionTests
final class MentionTests: XCTestCase {
    private let placeholder = "Say something nice"

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func field(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["composer"].firstMatch
    }

    private func shown(_ e: XCUIElement) -> String {
        let v = (e.value as? String) ?? ""
        return v == placeholder ? "" : v
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func text(_ app: XCUIApplication, containing s: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
    }

    private func launch(_ rt: String, _ user: String, _ appearance: String, agent: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiRefreshToken", rt, "-yuiUserID", user, "-yuiAgent", agent, "-appearance", appearance]
        app.launch()
        return app
    }

    func testMentionLightThenDark() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rts = env["YUI_RTS"]?.split(separator: ",").map(String.init), rts.count >= 2,
              let user = env["YUI_USER"] else {
            throw XCTSkip("set TEST_RUNNER_YUI_RTS (two refresh tokens) and TEST_RUNNER_YUI_USER; see mention_e2e.py")
        }

        // Light: ask Bravo from Alpha's thread.
        let app = launch(rts[0], user, "light", agent: "alpha")
        let input = field(app)
        XCTAssertTrue(input.waitForExistence(timeout: 30), "no composer")
        sleep(2)  // the agent list loads after sign-in
        input.tap()
        input.typeText("@")
        let popover = any(app, "mention")
        XCTAssertTrue(popover.waitForExistence(timeout: 10), "no agents for @")
        XCTAssertTrue(any(app, "mention-bravo").waitForExistence(timeout: 5))
        XCTAssertTrue(any(app, "mention-bravo").label.hasPrefix("Bravo, Online"), any(app, "mention-bravo").label)
        XCTAssertTrue(any(app, "mention-cleo").label.hasPrefix("Cleo, Offline"), any(app, "mention-cleo").label)
        XCTAssertFalse(any(app, "mention-alpha").exists, "never the agent you're in")
        shot("mention-light-01-popover")

        input.typeText("b")
        XCTAssertTrue(any(app, "mention-bravo").waitForExistence(timeout: 5))
        XCTAssertFalse(any(app, "mention-cleo").exists, "@b leaves Cleo out")
        any(app, "mention-bravo").tap()
        XCTAssertEqual(shown(input), "@Bravo ")
        XCTAssertFalse(popover.exists, "the popover closes once the name is in")
        XCTAssertTrue(any(app, "mention-bar").waitForExistence(timeout: 5), "no 'Goes to Bravo' line")
        input.typeText("does this fit my knee?")
        shot("mention-light-02-token")
        app.buttons["Send"].tap()
        XCTAssertEqual(shown(input), "", "sent")
        XCTAssertTrue(any(app, "mention-chip").waitForExistence(timeout: 10), "the sent bubble says To Bravo")

        // Bravo's answer lands here, in Bravo's look, with a way into its thread.
        let answer = text(app, containing: "Box squats")
        XCTAssertTrue(answer.waitForExistence(timeout: 120), "Bravo's answer never came back to Alpha's thread")
        XCTAssertTrue(app.buttons["Open Bravo's thread"].waitForExistence(timeout: 5))
        sleep(1)
        shot("mention-light-03-answer")

        // An offline agent says so instead of silence.
        input.tap()
        input.typeText("@Cleo you there?")
        app.buttons["Send"].tap()
        XCTAssertTrue(text(app, containing: "Cleo is offline").waitForExistence(timeout: 30), "no offline line for Cleo")
        sleep(1)
        shot("mention-light-04-offline")
        app.terminate()

        // Dark: the thread reopens with Bravo's answer in its look; its thread is one tap away.
        let dark = launch(rts[1], user, "dark", agent: "alpha")
        XCTAssertTrue(text(dark, containing: "Box squats").waitForExistence(timeout: 30), "answer gone after reopening")
        sleep(1)
        shot("mention-dark-01-thread")
        let open = dark.buttons["Open Bravo's thread"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        XCTAssertTrue(text(dark, containing: "from Alpha's thread").waitForExistence(timeout: 20),
                      "Bravo's thread doesn't show where the question came from")
        XCTAssertTrue(text(dark, containing: "does this fit my knee?").exists)
        sleep(1)
        shot("mention-dark-02-bravo-thread")
    }
}
