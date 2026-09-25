import XCTest

/// An A2A agent in Yui (INT-18), against the live relay. Driven by
/// `adapters/a2a/tests/a2a_e2e.py --sim <udid>`: a throwaway account whose one
/// agent, Echo, is a scripted A2A agent behind the local A2A bridge.
///
///   1. Light: a long task shows the working row, then its whole answer lands.
///      A Yui screen from the A2A agent draws, and a tap on it is answered.
///   2. Dark, relaunched: the agent asks a question (input-required); the
///      answer continues the same task.
///
/// Each launch needs its own fresh refresh token (TEST_RUNNER_YUI_RTS, two).
final class A2ATests: XCTestCase {
    func testA2AAgentAnswers() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rts = env["YUI_RTS"]?.split(separator: ",").map(String.init), rts.count >= 2,
              let user = env["YUI_USER"], let dir = env["YUI_SHOTS"] else {
            throw XCTSkip("run through adapters/a2a/tests/a2a_e2e.py --sim <udid>")
        }
        let shots = URL(fileURLWithPath: dir)
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            try? png.write(to: shots.appending(path: "\(name).png"))
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = name
            a.lifetime = .keepAlways
            add(a)
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let app = XCUIApplication()
        func text(_ s: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
        }
        func launch(_ n: Int, _ appearance: String) {
            app.launchArguments = ["-yuiRefreshToken", rts[n], "-yuiUserID", user, "-appearance", appearance]
            app.launch()
            let allow = springboard.buttons["Allow"]
            if allow.waitForExistence(timeout: 6) { allow.tap() }
        }
        let field = app.descendants(matching: .any).matching(
            NSPredicate(format: "placeholderValue == %@ OR label == %@", "Say something nice", "Say something nice")).firstMatch
        func say(_ s: String) {
            XCTAssertTrue(field.waitForExistence(timeout: 20))
            field.tap()
            field.typeText(s)
            app.buttons["Send"].tap()
        }

        // 1. Light: a long task, then a screen and a tap.
        launch(0, "light")
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        say("Run the slow report, 6 steps")
        XCTAssertTrue(app.descendants(matching: .any)["working"].firstMatch.waitForExistence(timeout: 20),
                      "no working row while the A2A task runs")
        sleep(3)
        shot("01-working-light")
        XCTAssertTrue(text("Done after 6 steps.").waitForExistence(timeout: 60), "the long task's answer never landed")
        XCTAssertTrue(text("Step 1, step 2, step 3, step 4, step 5, step 6").exists, "the streamed chunks did not add up")
        sleep(1)
        shot("02-done-light")
        say("Show me a screen")
        let tea = app.buttons["Tea"].firstMatch
        XCTAssertTrue(tea.waitForExistence(timeout: 30), "the A2A agent's Yui screen did not draw")
        sleep(1)
        shot("03-screen-light")
        tea.tap()
        XCTAssertTrue(text("Tea it is.").waitForExistence(timeout: 30), "the tap was not answered")
        sleep(1)
        shot("04-tapped-light")
        app.terminate()

        // 2. Dark: input-required, then the answer continues the task.
        launch(1, "dark")
        say("Ask me something")
        XCTAssertTrue(text("Which color?").waitForExistence(timeout: 30), "the agent's question never landed")
        say("Blue")
        XCTAssertTrue(text("Blue it is.").waitForExistence(timeout: 30), "the answer did not finish the task")
        sleep(1)
        shot("05-asks-dark")
    }
}
