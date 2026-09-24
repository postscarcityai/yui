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
}
