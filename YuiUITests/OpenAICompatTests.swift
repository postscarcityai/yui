import XCTest

/// A local model in Yui (INT-12), against the live relay. Driven by
/// `adapters/openai-compat/tests/openai_e2e.py --run phone --sim <udid>`: a
/// throwaway account whose one agent, Qwen, is qwen2.5:7b on this Mac's
/// Ollama behind the model bridge. A real model, so the checks look for what
/// the prompt pins down (the two options, one word back), not exact wording.
///
///   1. Light: the working row while the model answers, then its Yui screen
///      draws; a tap on Tea goes back as the next turn and is answered.
///   2. Dark, relaunched: a question that needs the thread (what did I pick?).
///
/// Each launch needs its own fresh refresh token (TEST_RUNNER_YUI_RTS, two).
final class OpenAICompatTests: XCTestCase {
    func testLocalModelAnswersWithAScreen() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rts = env["YUI_RTS"]?.split(separator: ",").map(String.init), rts.count >= 2,
              let user = env["YUI_USER"], let dir = env["YUI_SHOTS"] else {
            throw XCTSkip("run through adapters/openai-compat/tests/openai_e2e.py --run phone --sim <udid>")
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
        let working = app.descendants(matching: .any)["working"].firstMatch
        /// The working row came and went: the model's answer is in.
        func answered(_ what: String) {
            XCTAssertTrue(working.waitForExistence(timeout: 30), "no working row while the model answers \(what)")
            let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: working)
            wait(for: [gone], timeout: 240)
        }

        // 1. Light: the model's screen, a tap, its answer.
        launch(0, "light")
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        say("Show me a choose screen titled Drink with exactly two options: Tea and Coffee.")
        XCTAssertTrue(working.waitForExistence(timeout: 30), "no working row while the model answers")
        sleep(2)
        shot("01-working-light")
        let tea = app.buttons["Tea"].firstMatch
        XCTAssertTrue(tea.waitForExistence(timeout: 240), "the model's Yui screen did not draw")
        XCTAssertTrue(app.buttons["Coffee"].firstMatch.exists, "the screen is missing Coffee")
        sleep(1)
        shot("02-screen-light")
        tea.tap()
        answered("the tap")
        sleep(1)
        shot("03-tapped-light")
        app.terminate()

        // 2. Dark: it remembers the tap, because Yui holds the thread.
        launch(1, "dark")
        XCTAssertTrue(tea.waitForExistence(timeout: 30), "the thread did not come back after a relaunch")
        say("Which drink did I just pick? Answer in one word, in capital letters.")
        answered("the question")
        let remembered = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "TEA")).firstMatch
        XCTAssertTrue(remembered.waitForExistence(timeout: 10), "the answer did not name the pick")
        sleep(1)
        shot("04-remembers-dark")
    }
}
