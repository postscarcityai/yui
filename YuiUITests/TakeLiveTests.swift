import XCTest

/// YUI-116 step 5 end to end (supabase/tests/take_e2e.py --sim <udid>): a
/// signed-in phone gets a loop from a real Yui host, records a take, and the
/// agent receives it as links it can open. The script is the host and the judge;
/// this test is the person.
///
///   1. Signed in, the app is up: ask for the beat (need-beat).
///   2. The loop arrives and plays. Record about 4 s, Stop and send.
///   3. The take goes up like a photo; the agent gets the event and answers
///      with the take as a link (need-got, then the reply on screen).
final class TakeLiveTests: XCTestCase {
    func testTakeReachesTheAgent() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rts = env["YUI_RTS"]?.split(separator: ",").map(String.init), !rts.isEmpty,
              let user = env["YUI_USER"], let dir = env["YUI_SHOTS"] else {
            throw XCTSkip("run through supabase/tests/take_e2e.py --sim <udid>")
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
        func ask(_ what: String, timeout: TimeInterval) -> Bool {
            FileManager.default.createFile(atPath: shots.appending(path: "need-\(what)").path, contents: nil)
            let ok = shots.appending(path: "\(what)-ok").path
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                if FileManager.default.fileExists(atPath: ok) { return true }
                usleep(300_000)
            }
            return false
        }
        let app = XCUIApplication()
        app.launchArguments = ["-yuiRefreshToken", rts[0], "-yuiUserID", user, "-appearance", "light"]
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 6) { allow.tap() }
        let up = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'stage-first' OR placeholderValue == 'Say something nice' OR label == 'Say something nice'")).firstMatch
        XCTAssertTrue(up.waitForExistence(timeout: 30), "the app never came up")
        sleep(2)

        // 1. The agent sends a beat.
        XCTAssertTrue(ask("beat", timeout: 30), "the host never sent the beat")
        let rec = app.buttons["take-record"]
        XCTAssertTrue(rec.waitForExistence(timeout: 60), "the loop never arrived")
        sleep(1)
        shot("1-beat")

        // 2. Record about 4 s of it playing (+play), then send.
        if app.buttons["loop-play"].label == "Play" { app.buttons["loop-play"].tap() }
        rec.tap()
        sleep(4)
        shot("2-recording")
        rec.tap()
        let status = app.staticTexts["take-status"]
        let end = Date().addingTimeInterval(60)
        while Date() < end, !status.label.hasPrefix("Take sent") { usleep(300_000) }
        XCTAssertTrue(status.label.hasPrefix("Take sent"), "the take did not send: \(status.label)")
        shot("3-sent")

        // 3. The agent got it as links and answers.
        XCTAssertTrue(ask("got", timeout: 90), "the agent never got the take")
        let reply = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Got your take")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 60), "no answer from the agent on screen")
        sleep(2)
        shot("4-answer")
    }
}
