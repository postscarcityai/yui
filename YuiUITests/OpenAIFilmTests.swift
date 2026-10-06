import XCTest

/// A small local model explains with a film (INT-28), against the live relay.
/// Driven by `adapters/openai-compat/tests/openai_e2e.py --run film --sim <udid>`:
/// the bridge answers "how does a rainbow form?" with one line and a motion
/// line. Light then dark, each on its own launch (own fresh refresh token), and
/// the shot is the thread with the film as the phone draws it. A real model,
/// so the checks only wait for the working row to come and go.
final class OpenAIFilmTests: XCTestCase {
    func testSmallModelExplainsWithAFilm() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rts = env["YUI_RTS"]?.split(separator: ",").map(String.init), rts.count >= 2,
              let user = env["YUI_USER"], let agent = env["YUI_AGENT"], let dir = env["YUI_SHOTS"] else {
            throw XCTSkip("run through adapters/openai-compat/tests/openai_e2e.py --run film --sim <udid>")
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
            app.launchArguments = ["-yuiRefreshToken", rts[n], "-yuiUserID", user, "-selectedAgent", agent, "-yuiStageFirst", "NO", "-appearance", appearance]
            app.launch()
            let allow = springboard.buttons["Allow"]
            if allow.waitForExistence(timeout: 6) { allow.tap() }
        }
        let field = app.descendants(matching: .any).matching(
            NSPredicate(format: "placeholderValue == %@ OR label == %@", "Say something nice", "Say something nice")).firstMatch
        let working = app.descendants(matching: .any)["working"].firstMatch
        func ask(_ s: String) {
            XCTAssertTrue(field.waitForExistence(timeout: 30))
            field.tap()
            if !app.keyboards.firstMatch.waitForExistence(timeout: 5) { field.tap() }
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "no keyboard to type on")
            field.typeText(s)
            app.buttons["Send"].tap()
            XCTAssertTrue(working.waitForExistence(timeout: 30), "no working row while the model answers")
            let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: working)
            wait(for: [gone], timeout: 240)
            sleep(20) // the film opens full screen and makes its first frame
        }
        /// A film that opened full screen covers the composer: close it, as a person would.
        func closeFilm() {
            let close = app.buttons["Close"]
            if close.waitForExistence(timeout: 5) { close.tap() }
        }
        launch(0, "light")
        ask("how does a rainbow form?")
        shot("film-light")
        closeFilm()
        app.terminate()
        launch(1, "dark")
        closeFilm()
        ask("how does a bill become law?")
        shot("film-dark")
        closeFilm()
    }
}
