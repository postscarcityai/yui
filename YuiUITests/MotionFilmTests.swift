import XCTest

/// A film in the thread (spec/MOTION.md section 0.5): the agent's one-line ask became a `motion` block in three
/// rows (scene 1, the rest, a closing row). The native player opens full screen, plays the real kit, and the
/// later parts feed it. Demo account, no network, dark and light. YUI_MOTION_FILM=<gallery film json> plays a
/// real film (default: a short one written here); YUI_SHOTS=<dir> keeps the screenshots.
final class MotionFilmTests: XCTestCase {
    private let tmp = FileManager.default.temporaryDirectory

    private func scenes() -> [[String: Any]] {
        let env = ProcessInfo.processInfo.environment
        if let p = env["YUI_MOTION_FILM"], let d = FileManager.default.contents(atPath: p),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let s = j["scenes"] as? [[String: Any]] { return s }
        return [
            ["name": "hook", "dur": 4.0, "code": "api.look('agent');\napi.shape('heart', api.w/2, api.h*0.4, 200, {c:'accent', fill:'accent', k: api.seg(t,0,1.5)});\napi.say('A heart is a pump', 0.4, 3.6);"],
            ["name": "beat", "dur": 5.0, "code": "api.look('agent');\nconst s = 1 + 0.12*Math.sin(t*6);\napi.cam(0,0,s,0);\napi.shape('heart', api.w/2, api.h*0.4, 200, {c:'accent', fill:'accent'});\napi.cam0();\napi.callout('It squeezes', api.w/2, api.h*0.4, 110, 640, {k: api.seg(t,0.5,1.5)});\napi.say('Squeeze, relax', 0.3, 4.6);"],
            ["name": "flow", "dur": 5.0, "code": "api.look('agent');\nconst A = api.node(100, 300, 120, 56, 'Lungs', {k: api.seg(t,0,1)});\nconst B = api.node(290, 300, 120, 56, 'Body', {k: api.seg(t,0.4,1.4)});\napi.link(A, B, {k: api.seg(t,1,2), flow: t});\napi.say('Blood goes round', 0.3, 4.6);"],
        ]
    }

    private func block(_ head: String, _ ss: [[String: Any]]) -> String {
        var t = "```yui\n" + head + "\n"
        for s in ss { t += "=== scene \(s["name"] as? String ?? "s") \(s["dur"] as? Double ?? 5) ===\n\(s["code"] as? String ?? "")\n" }
        return t + "end\n```"
    }

    private func rows() -> [[String: Any]] {
        let ss = scenes()
        let a = Array(ss.prefix(2)), b = Array(ss.dropFirst(2))
        func row(_ id: String, _ sender: String, _ body: String, _ at: Int) -> [String: Any] {
            ["id": id, "sender": sender, "kind": "text", "body": body, "created_at": String(format: "2026-10-06T10:00:%02d+00:00", at)]
        }
        return [
            row("u1", "user", "Draw how a heart pumps blood", 1),
            row("a1", "agent", "```yui\nsay Here it is.\n```\n" + block("motion \"How a heart pumps blood\" film=m7 part=1", a), 2),
            row("a2", "agent", block("motion film=m7 part=2", b), 3),
            row("a3", "agent", "```yui\nmotion film=m7 part=3 +last\n```", 4),
        ]
    }

    private func run(_ look: String) throws {
        let env = ProcessInfo.processInfo.environment
        let path = tmp.appending(path: "yui-motion-rows-\(look).json")
        try JSONSerialization.data(withJSONObject: rows()).write(to: path)
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiAgent", "yui", "-appearance", look,
                               "-yuiThreadRows", path.path, "-yuiMotionOpen"]
        app.launch()
        // The tile opened the player on its own (the launch argument stands in for "arrived while you were here").
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 20), "the film did not open full screen")
        func shot(_ name: String) {
            guard let dir = env["YUI_SHOTS"] else { return }
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "motion-film-\(name)-\(look).png"))
        }
        Thread.sleep(forTimeInterval: 2.5); shot("a")
        Thread.sleep(forTimeInterval: 4.0); shot("b")
        Thread.sleep(forTimeInterval: 6.0); shot("c")
        // A tap brings the chrome back: pause, the speaker (the film has say lines), the scrubber.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(app.buttons["motion.mute"].waitForExistence(timeout: 5), "a film with say lines shows the mute button")
        shot("mute")
        // The chrome may have faded by now; the mute toggle itself is covered by MotionSpeechTests.
        if app.buttons["motion.mute"].exists {
            app.buttons["motion.mute"].tap()
            shot("muted")
            if app.buttons["motion.mute"].exists { app.buttons["motion.mute"].tap() }
        }
        XCTAssertTrue(close.exists, "the player closed on its own or fell back")
        close.tap()
        XCTAssertTrue(app.buttons["motion-tile"].waitForExistence(timeout: 10), "closing the film leaves its tile in the thread")
    }

    func testFilmPlaysFullScreenDark() throws { try run("dark") }
    func testFilmPlaysFullScreenLight() throws { try run("light") }
}
