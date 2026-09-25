import XCTest

/// Presence per agent (YUI-64), against the live relay. Driven by
/// `supabase/tests/listening_e2e.py --sim <udid>`: one throwaway computer
/// with two agents, Alpha (its gateway runs, a real Yui adapter) and Bravo
/// (paired, no gateway yet).
///
///   1. Light: the agent list says Bravo is not listening yet while Alpha is
///      online. Bravo's sheet names the one step left with the exact command.
///      A message to Bravo says it waits, not a working timer.
///   2. Dark, relaunched: the same, then the driver starts Bravo's gateway and
///      the message that waited is answered.
///
/// Each launch needs its own fresh refresh token (TEST_RUNNER_YUI_RTS, two).
final class ListeningTests: XCTestCase {
    func testNotListeningYet() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rts = env["YUI_RTS"]?.split(separator: ",").map(String.init), rts.count >= 2,
              let user = env["YUI_USER"], let dir = env["YUI_SHOTS"] else {
            throw XCTSkip("run through supabase/tests/listening_e2e.py --sim <udid>")
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
        func handshake(_ ask: String, timeout: TimeInterval = 120) {
            try? Data().write(to: shots.appending(path: "need-\(ask)"))
            let done = shots.appending(path: "\(ask)-ok")
            let end = Date.now.addingTimeInterval(timeout)
            while !FileManager.default.fileExists(atPath: done.path), Date.now < end { sleep(1) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: done.path), "driver never did \(ask)")
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let app = XCUIApplication()
        func text(_ s: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
        }
        func launch(_ n: Int, _ appearance: String, list: Bool) {
            app.launchArguments = ["-yuiRefreshToken", rts[n], "-yuiUserID", user, "-appearance", appearance]
                + (list ? ["-yuiAgents"] : [])
            app.launch()
            let allow = springboard.buttons["Allow"]
            if allow.waitForExistence(timeout: 6) { allow.tap() }
        }
        func restartStep() {
            let edit = app.buttons["Edit Bravo"].firstMatch
            XCTAssertTrue(edit.waitForExistence(timeout: 20))
            edit.tap()
            XCTAssertTrue(app.descendants(matching: .any)["restart-step"].firstMatch.waitForExistence(timeout: 10),
                          "Bravo's sheet does not name the step left")
            XCTAssertTrue(text("hermes -p bravo gateway restart").exists, "no exact restart command")
            XCTAssertTrue(text("Not listening yet").exists)
        }
        let field = app.descendants(matching: .any).matching(
            NSPredicate(format: "placeholderValue == %@ OR label == %@", "Say something nice", "Say something nice")).firstMatch
        let waits = text("isn't listening yet. This waits")

        // 1. Light: the list, the sheet, a message that waits.
        launch(0, "light", list: true)
        XCTAssertTrue(text("Not listening yet").waitForExistence(timeout: 20), "the list does not say Bravo isn't listening")
        XCTAssertTrue(text("Online").exists, "Alpha, whose gateway runs, is not online")
        sleep(1)
        shot("01-agents-light")
        restartStep()
        sleep(1)
        shot("02-one-step-left-light")
        app.buttons["Cancel"].tap()
        // A tap on Bravo's row opens its thread (and the next launch reopens it).
        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Bravo")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        XCTAssertTrue(text("Bravo isn't listening yet. Messages wait").waitForExistence(timeout: 10))
        shot("03-empty-thread-light")
        field.tap()
        field.typeText("hi Bravo, are you there?")
        app.buttons["Send"].tap()
        XCTAssertTrue(waits.waitForExistence(timeout: 20), "no waiting note for a not-listening agent")
        XCTAssertFalse(app.descendants(matching: .any)["working"].exists, "a working timer counts for an agent nobody reads")
        sleep(3)
        XCTAssertFalse(app.descendants(matching: .any)["working"].exists)
        shot("04-message-waits-light")
        app.terminate()

        // 2. Dark: still waiting after a relaunch; the gateway starts; the answer lands.
        launch(1, "dark", list: false)
        XCTAssertTrue(waits.waitForExistence(timeout: 30), "the waiting note is gone after a relaunch")
        XCTAssertFalse(app.descendants(matching: .any)["working"].exists)
        shot("05-message-waits-dark")
        handshake("wake")
        let answer = text("echo: hi Bravo, are you there?")
        XCTAssertTrue(answer.waitForExistence(timeout: 90), "Bravo never answered once its gateway started")
        XCTAssertTrue(waits.waitForNonExistence(timeout: 10), "the waiting note stayed after the answer")
        XCTAssertTrue(app.buttons["Talking to Bravo, online"].waitForExistence(timeout: 20), "the header still says not listening")
        sleep(2)
        shot("06-answered-dark")
    }
}
