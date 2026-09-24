import XCTest

/// Live push handoff (YUI-8): the app registers for pushes, goes to the
/// background, an agent hands something off from another channel ("send it
/// to Yui"), the banner arrives, and tapping it opens the thread with the
/// screen. Needs a real session, a Mac whose simulator gets sandbox APNs
/// tokens (Apple silicon), and someone to trigger the handoff while the test
/// waits (it writes `YUI_SHOTS/ready` once the app is in the background).
/// Use a FRESH refresh token per run (see RelayRoundTripTests).
///
///   TEST_RUNNER_YUI_RT=<refresh token> TEST_RUNNER_YUI_USER=<uuid> TEST_RUNNER_YUI_SHOTS=/tmp/shots TEST_RUNNER_YUI_EXPECT=<a button label> \
///     xcodebuild test -scheme Yui -destination '...' -only-testing:YuiUITests/PushHandoffTests
final class PushHandoffTests: XCTestCase {
    func testPushOpensThread() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rt = env["YUI_RT"], let user = env["YUI_USER"] else {
            throw XCTSkip("set TEST_RUNNER_YUI_RT and TEST_RUNNER_YUI_USER to run against the live relay")
        }
        let shots = env["YUI_SHOTS"].map { URL(fileURLWithPath: $0) }
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            if let shots { try? png.write(to: shots.appending(path: "\(name).png")) }
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = name
            a.lifetime = .keepAlways
            add(a)
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        let app = XCUIApplication()
        app.launchArguments = ["-yuiRefreshToken", rt, "-yuiUserID", user, "-appearance", "light"]
        app.launch()

        // First launch asks for notification permission.
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 15) {
            shot("01-permission")
            allow.tap()
        }
        let field = app.descendants(matching: .any).matching(NSPredicate(format: "placeholderValue == %@ OR label == %@", "Say something nice", "Say something nice")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        sleep(5)  // device token -> yui-push register
        shot("02-thread-before")

        XCUIDevice.shared.press(.home)
        if let shots { try? Data("ready".utf8).write(to: shots.appending(path: "ready")) }

        // The handoff happens outside the test (Hermes). Wait for its banner.
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "something for you")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 300), "no push arrived")
        shot("03-push-banner")
        banner.tap()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        // The handed-off screen is rendered: one of its buttons (TEST_RUNNER_YUI_EXPECT).
        let choice = app.buttons[env["YUI_EXPECT"] ?? "Ship it"].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 20), "the thread opened without the handed-off screen")
        sleep(3)
        shot("04-thread-opened")
    }

    /// Reply pushes (YUI-24), driven by supabase/tests/push_killed_e2e.py:
    /// open on the default agent's thread, an answer there arrives with no push
    /// (the server sees the app on that thread); then the app is KILLED, another
    /// agent answers, the push arrives, and tapping it cold-starts the app
    /// straight into that agent's thread. The driver makes a throwaway account
    /// and a fresh session per run and deletes both after.
    func testReplyPushOpensThreadFromKilledApp() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rt = env["YUI_RT"], let user = env["YUI_USER"], let dir = env["YUI_SHOTS"],
              let other = env["YUI_OTHER_AGENT"] else {
            throw XCTSkip("run supabase/tests/push_killed_e2e.py")
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
        func signal(_ name: String) { try? Data(name.utf8).write(to: shots.appending(path: name)) }
        func waitFor(_ name: String, timeout: TimeInterval) -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                if FileManager.default.fileExists(atPath: shots.appending(path: name).path) { return true }
                usleep(500_000)
            }
            return false
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", other)).firstMatch

        let app = XCUIApplication()
        app.launchArguments = ["-yuiRefreshToken", rt, "-yuiUserID", user, "-appearance", "light"]
        app.launch()
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 15) { allow.tap() }
        let field = app.descendants(matching: .any).matching(NSPredicate(format: "placeholderValue == %@ OR label == %@", "Say something nice", "Say something nice")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        signal("open")  // driver: waits for register + presence, then answers in this thread

        // Open on the thread: the answer shows up in it, and no banner.
        let answer = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Answered while you watch")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 90), "open-thread answer never showed")
        XCTAssertFalse(banner.waitForExistence(timeout: 8), "a push arrived while the thread was open")
        shot("01-open-no-push")

        app.terminate()
        signal("killed")  // driver: the other agent answers now

        XCTAssertTrue(banner.waitForExistence(timeout: 240), "no push arrived for the killed app")
        shot("02-push-banner")
        banner.tap()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        let header = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Talking to \(other)")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 20), "the tap did not open \(other)'s thread")
        XCTAssertTrue(app.buttons["Ship it"].firstMatch.waitForExistence(timeout: 20), "the thread opened without the answer")
        sleep(2)
        shot("03-thread-opened")
    }
}
