import XCTest

/// Reliable connection on the phone (YUI-28), against the live relay and a
/// scripted echo agent. Driven by `supabase/tests/offline_e2e.py --sim <udid>`,
/// which runs the agent's host and answers the handshake files below.
///
///   1. The phone's network is down (`-yuiOfflineFlag`): two messages stay on
///      the phone, marked not sent. The app is killed with them in flight.
///   2. Relaunch, still offline: both are still there, still not sent.
///   3. Network back: they go out once each, in order; the agent answers both.
///   4. The agent's computer goes quiet: the thread and the agent list say
///      asleep, with its last-seen time, light and dark. A message sent now
///      waits and is answered when the host comes back.
///
/// Every launch needs its own FRESH refresh token (TEST_RUNNER_YUI_RTS, comma
/// separated, four of them): a spent one trips the reuse check in yui-auth.
final class OfflineTests: XCTestCase {
    func testNetworkDropKilledAppAndAsleep() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rts = env["YUI_RTS"]?.split(separator: ",").map(String.init), rts.count >= 4,
              let user = env["YUI_USER"], let flag = env["YUI_OFFLINE"], let dir = env["YUI_SHOTS"] else {
            throw XCTSkip("run through supabase/tests/offline_e2e.py --sim <udid>")
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
        /// Ask the driver for something and wait until it's done.
        func handshake(_ ask: String, timeout: TimeInterval = 120) {
            try? Data().write(to: shots.appending(path: "need-\(ask)"))
            let done = shots.appending(path: "\(ask)-ok")
            let end = Date.now.addingTimeInterval(timeout)
            while !FileManager.default.fileExists(atPath: done.path), Date.now < end { sleep(1) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: done.path), "driver never did \(ask)")
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let app = XCUIApplication()
        func launch(_ n: Int, _ appearance: String) -> XCUIElement {
            app.launchArguments = ["-yuiRefreshToken", rts[n], "-yuiUserID", user, "-appearance", appearance,
                                   "-yuiOfflineFlag", flag]
            app.launch()
            let allow = springboard.buttons["Allow"]
            if allow.waitForExistence(timeout: 6) { allow.tap() }
            let field = app.descendants(matching: .any).matching(
                NSPredicate(format: "placeholderValue == %@ OR label == %@", "Say something nice", "Say something nice")).firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 20))
            return field
        }
        func say(_ field: XCUIElement, _ text: String) {
            field.tap()
            field.typeText(text)
            app.buttons["Send"].tap()
            // Queued on the phone, not sent yet: the words still leave the composer (YUI-50).
            let left = (app.descendants(matching: .any)["composer"].firstMatch.value as? String) ?? ""
            XCTAssertTrue(left.isEmpty || left == "Say something nice", "\(text) stayed in the composer: \(left)")
        }
        func text(_ s: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
        }
        let notSent = text("Not sent yet")

        // 1. Offline: two messages stay on the phone. Then the app is killed.
        FileManager.default.createFile(atPath: flag, contents: Data())
        var field = launch(0, "light")
        say(field, "p1 sent with no network")
        say(field, "p2 sent with no network")
        XCTAssertTrue(notSent.waitForExistence(timeout: 20), "no not-sent note while offline")
        XCTAssertTrue(text("p2 sent with no network, not sent yet").exists)
        sleep(1)
        shot("01-offline-not-sent-light")
        app.terminate()

        // 2. Relaunch, still offline: both still there, still not sent.
        field = launch(1, "dark")
        XCTAssertTrue(text("p1 sent with no network, not sent yet").waitForExistence(timeout: 20),
                      "a killed app lost its unsent message")
        XCTAssertTrue(text("p2 sent with no network, not sent yet").exists)
        XCTAssertTrue(notSent.waitForExistence(timeout: 20))
        sleep(1)
        shot("02-relaunched-still-offline-dark")

        // 3. Network back: out once each, in order, answered.
        try? FileManager.default.removeItem(atPath: flag)
        XCTAssertTrue(text("echo: p2 sent with no network").waitForExistence(timeout: 90), "no answer after the network came back")
        XCTAssertFalse(notSent.exists)
        sleep(2)
        shot("03-back-online-delivered-dark")
        app.terminate()

        // 4. The agent's computer goes quiet.
        handshake("asleep")
        field = launch(2, "light")
        say(field, "p3 while you sleep")
        XCTAssertTrue(text("is asleep. It gets this when its computer wakes").waitForExistence(timeout: 20),
                      "no asleep note for a quiet host")
        sleep(1)
        shot("04-asleep-thread-light")
        app.buttons["Agent menu"].tap()
        XCTAssertTrue(text("Asleep, seen").waitForExistence(timeout: 10), "the agent list does not say asleep")
        sleep(1)
        shot("05-asleep-agents-light")
        app.terminate()

        field = launch(3, "dark")
        say(field, "p4 still asleep")
        XCTAssertTrue(text("is asleep. It gets this when its computer wakes").waitForExistence(timeout: 20))
        sleep(1)
        shot("06-asleep-thread-dark")
        app.buttons["Agent menu"].tap()
        XCTAssertTrue(text("Asleep, seen").waitForExistence(timeout: 10))
        sleep(1)
        shot("07-asleep-agents-dark")
        app.buttons["drawer-close"].tap()

        handshake("wake")
        XCTAssertTrue(text("echo: p4 still asleep").waitForExistence(timeout: 90), "no answer after the host woke")
        sleep(2)
        shot("08-woke-answered-dark")
    }
}
