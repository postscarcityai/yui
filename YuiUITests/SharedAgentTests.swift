import XCTest

/// Shared agents (YUI-95), against the live backend. Driven by
/// `supabase/tests/shared_agents_e2e.py --sim <udid>`: a throwaway owner
/// shares Penny (client-safe host, look candy, a first message) through a
/// template on an @example.com invite; the throwaway invitee claims it and
/// signs in here.
///
///   1. Light: the invitee's list has Penny, the first message waits in her thread.
///   2. Dark, relaunched: the same.
///   3. The driver revokes the grant; relaunched, Penny is gone from the list.
///
/// Each launch needs its own fresh refresh token (TEST_RUNNER_YUI_RTS, three).
final class SharedAgentTests: XCTestCase {
    func testGrantedAgentThenRevoke() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rts = env["YUI_RTS"]?.split(separator: ",").map(String.init), rts.count >= 3,
              let user = env["YUI_USER"], let dir = env["YUI_SHOTS"], let hello = env["YUI_HELLO"] else {
            throw XCTSkip("run through supabase/tests/shared_agents_e2e.py --sim <udid>")
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
        func launch(_ n: Int, _ appearance: String) {
            app.launchArguments = ["-yuiRefreshToken", rts[n], "-yuiUserID", user, "-appearance", appearance, "-yuiAgents"]
            app.launch()
            let allow = springboard.buttons["Allow"]
            if allow.waitForExistence(timeout: 6) { allow.tap() }
        }
        let penny = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Penny")).firstMatch
        let firstLine = String(hello.prefix(24))

        for (n, look) in ["light", "dark"].enumerated() {
            launch(n, look)
            XCTAssertTrue(penny.waitForExistence(timeout: 30), "the invitee's list has no Penny (\(look))")
            sleep(1)
            shot("0\(2 * n + 1)-list-\(look)")
            penny.tap()
            XCTAssertTrue(text(firstLine).waitForExistence(timeout: 20), "Penny's first message is not waiting (\(look))")
            sleep(1)
            shot("0\(2 * n + 2)-thread-\(look)")
            app.terminate()
        }

        handshake("revoke")
        launch(2, "light")
        sleep(4)  // the list loads
        XCTAssertFalse(penny.exists, "Penny is still in the list after the revoke")
        XCTAssertFalse(text(firstLine).exists, "the revoked thread still shows")
        shot("05-revoked-light")
    }
}
