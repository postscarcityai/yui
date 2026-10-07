import XCTest

/// A film ends with Replay, Another take and Change it (YUI-320). Demo account, no network, a short film written here.
/// Another take sends `[yui] m7 motion again ...` back to the thread; Change it closes the film, quotes its row above
/// the composer and brings the keyboard up. Reduce Motion shows the same three over the still. YUI_SHOTS=<dir> keeps shots.
final class MotionEndTests: XCTestCase {
    private let tmp = FileManager.default.temporaryDirectory

    private func rows() -> [[String: Any]] {
        let code = "api.look('agent');\napi.shape('heart', api.w/2, api.h*0.4, 200, {c:'accent', fill:'accent', k: api.seg(t,0,1)});\napi.say('A heart is a pump', 0.3, 1.4);"
        func row(_ id: String, _ sender: String, _ body: String, _ at: Int) -> [String: Any] {
            ["id": id, "sender": sender, "kind": "text", "body": body, "created_at": String(format: "2026-10-07T10:00:%02d+00:00", at)]
        }
        return [
            row("u1", "user", "Draw how a heart pumps blood", 1),
            row("a1", "agent", "```yui\nmotion \"How a heart pumps blood\" film=m7 part=1\n=== scene hook 2 ===\n\(code)\nend\n```", 2),
            row("a3", "agent", "```yui\nmotion film=m7 part=2 +last\n```", 3),
        ]
    }

    private func launch(_ look: String, reduce: Bool = false, log: String? = nil) throws -> XCUIApplication {
        let path = tmp.appending(path: "yui-motion-end-\(look).json")
        try JSONSerialization.data(withJSONObject: rows()).write(to: path)
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiAgent", "yui", "-appearance", look,
                               "-yuiThreadRows", path.path, "-yuiMotionOpen"]
            + (reduce ? ["-yuiReduceMotion"] : []) + (log.map { ["-yuiEventLog", $0] } ?? [])
        app.launch()
        return app
    }

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
    }

    private func ended(_ app: XCUIApplication, _ look: String) {
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 20), "the film did not open")
        let again = app.buttons["motion.again"]
        XCTAssertTrue(again.waitForExistence(timeout: 30), "the film end shows no Another take")
        XCTAssertTrue(app.buttons["motion.change"].exists, "no Change it")
        XCTAssertTrue(app.buttons["motion.replay"].exists, "no Replay")
        XCTAssertEqual(again.label, "Another take")
        XCTAssertEqual(app.buttons["motion.change"].label, "Change it")
    }

    func testEndShowsThreeButtonsLightAndDark() throws {
        for look in ["light", "dark"] {
            let app = try launch(look)
            ended(app, look)
            shot("motion-end-\(look)")
            app.terminate()
        }
    }

    func testReduceMotionStillHasTheSameButtons() throws {
        let app = try launch("light", reduce: true)
        ended(app, "light")
        shot("motion-end-reduce")
    }

    func testReplayPlaysAgain() throws {
        let app = try launch("light")
        ended(app, "light")
        app.buttons["motion.replay"].tap()
        XCTAssertTrue(app.buttons["motion.again"].waitForNonExistence(timeout: 5), "Replay left the end buttons up")
        XCTAssertTrue(app.buttons["motion.again"].waitForExistence(timeout: 30), "the replay never reached its end")
    }

    func testAnotherTakeClosesAndSendsTheTap() throws {
        let log = tmp.appending(path: "yui-motion-end-events.jsonl").path
        try? FileManager.default.removeItem(atPath: log)
        let app = try launch("light", log: log)
        ended(app, "light")
        app.buttons["motion.again"].tap()
        XCTAssertTrue(app.buttons["motion-tile"].waitForExistence(timeout: 10), "the film did not close")
        XCTAssertFalse(app.buttons["Close"].exists)
        Thread.sleep(forTimeInterval: 1)
        let sent = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        XCTAssertTrue(sent.contains("\"preset\":\"motion\"") && sent.contains("\"again\":true"), "no again tap in: \(sent)")
        XCTAssertTrue(sent.contains("How a heart pumps blood"), "the tap lost the film's title: \(sent)")
        shot("motion-end-after-take")
    }

    func testChangeItQuotesTheFilmAndOpensTheComposer() throws {
        let app = try launch("light")
        ended(app, "light")
        app.buttons["motion.change"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["reply-bar"].waitForExistence(timeout: 10), "no quote above the composer")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the composer did not come up")
        Thread.sleep(forTimeInterval: 1)
        shot("motion-end-change-it")
    }
}
