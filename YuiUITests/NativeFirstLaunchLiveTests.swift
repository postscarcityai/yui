import XCTest

/// A brand-new person on the live backend (YUI-134, NATIVE-1): sign in, find Yui already
/// talking with the crew in the list, tap a first choice, and hosted Yui answers. Nothing
/// is paired and nothing runs on a computer. Driven by supabase/tests/native_first_launch_e2e.py,
/// which makes a throwaway account, writes `replied` to YUI_SHOTS once Yui's answer is in
/// the database, and deletes the account after. A FRESH refresh token per run:
///
///   TEST_RUNNER_YUI_RT=<refresh token> TEST_RUNNER_YUI_USER=<uuid> TEST_RUNNER_YUI_SHOTS=/tmp/shots \
///     xcodebuild test -scheme Yui -destination '...' -only-testing:YuiUITests/NativeFirstLaunchLiveTests
final class NativeFirstLaunchLiveTests: XCTestCase {
    func testNewAccountTalksToHostedYui() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rt = env["YUI_RT"], let user = env["YUI_USER"], let dir = env["YUI_SHOTS"] else {
            throw XCTSkip("set TEST_RUNNER_YUI_RT, TEST_RUNNER_YUI_USER and TEST_RUNNER_YUI_SHOTS")
        }
        let shots = URL(fileURLWithPath: dir)
        func shot(_ name: String) {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: "\(name).png"))
        }
        let app = XCUIApplication()
        func text(_ s: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func allowNotifications() {
            let allow = springboard.buttons["Allow"]
            if allow.waitForExistence(timeout: 3) { allow.tap() }
        }

        app.launchArguments = ["-yuiRefreshToken", rt, "-yuiUserID", user, "-appearance", env["YUI_APPEARANCE"] ?? "light"]
        app.launch()

        // 1. First launch: Yui's thread, her first message on screen. No pairing anywhere.
        XCTAssertTrue(text("Your crew is here").waitForExistence(timeout: 45), "Yui's first message is not on screen")
        allowNotifications()
        XCTAssertFalse(app.buttons["Add your first agent"].exists, "the pairing first run shows")
        XCTAssertFalse(text("Pairing code").exists, "a pairing step shows")
        let getFit = app.buttons["Get fit"].firstMatch
        XCTAssertTrue(getFit.waitForExistence(timeout: 10), "Yui's first choice is missing")
        sleep(2)
        shot("01-yui-first")

        // 2. Tap a choice. Hosted Yui answers (the driver sees her reply land).
        getFit.tap()
        let replied = shots.appending(path: "replied")
        let end = Date().addingTimeInterval(120)
        while Date() < end && !FileManager.default.fileExists(atPath: replied.path) { sleep(1) }
        let words = (try? String(contentsOf: replied, encoding: .utf8)) ?? ""
        XCTAssertFalse(words.isEmpty, "Yui never answered")
        XCTAssertTrue(text(words).waitForExistence(timeout: 30), "Yui's answer is not on screen: \(words)")
        sleep(3)
        shot("02-yui-answers")

        // 3. The crew is already in the list. A second session (a spent refresh token signs out).
        if let rt2 = env["YUI_RT2"] {
            app.terminate()
            app.launchArguments = ["-yuiRefreshToken", rt2, "-yuiUserID", user, "-yuiAgents",
                                   "-appearance", env["YUI_APPEARANCE"] ?? "light"]
            app.launch()
        }
        func row(_ name: String) -> XCUIElement { app.buttons["Edit \(name)"].firstMatch }
        XCTAssertTrue(row("Yui").waitForExistence(timeout: 15), "the crew is not in the list")
        for name in ["Arnold", "Basil", "Gouda", "Penny"] { XCTAssertTrue(row(name).exists, "\(name) is not in the list") }
        sleep(2)
        shot("03-crew")
    }
}
