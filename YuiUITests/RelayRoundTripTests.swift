import XCTest

/// Live round trip against the relay (YUI-7): type to the agent, a Yui Lines
/// screen comes back, a tap goes to the agent, the agent answers with a timer.
/// Needs a real session and a running Hermes gateway. Use a FRESH refresh token per
/// run: a spent one trips the reuse check in yui-auth and signs out every device.
/// It only runs when
/// `TEST_RUNNER_YUI_RT` / `TEST_RUNNER_YUI_USER` are set:
///
///   TEST_RUNNER_YUI_RT=<refresh token> TEST_RUNNER_YUI_USER=<uuid> TEST_RUNNER_YUI_SHOTS=/tmp/shots \
///     xcodebuild test -scheme Yui -destination '...' -only-testing:YuiUITests
final class RelayRoundTripTests: XCTestCase {
    func testTalkTapTimer() throws {
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

        let app = XCUIApplication()
        app.launchArguments = ["-yuiRefreshToken", rt, "-yuiUserID", user, "-appearance", "light"]
        app.launch()

        let field = app.descendants(matching: .any).matching(NSPredicate(format: "placeholderValue == %@ OR label == %@", "Say something nice", "Say something nice")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        shot("01-thread-loaded")
        let timersBefore = app.buttons.matching(NSPredicate(format: "label == %@", "Start")).count

        field.tap()
        field.typeText("Testing Yui buttons: ask me \"Ready for a tabata?\" with buttons Yes and Not now. If I tap Yes, put up a 20/10x8 tabata timer.")
        app.buttons["Send"].tap()
        shot("02-sent")

        let yes = app.buttons["Yes"].firstMatch
        XCTAssertTrue(yes.waitForExistence(timeout: 120), "the agent's ask screen never arrived")
        sleep(1)
        shot("03-ask-rendered")

        yes.tap()
        shot("04-tapped-yes")

        let deadline = Date.now.addingTimeInterval(120)
        while app.buttons.matching(NSPredicate(format: "label == %@", "Start")).count <= timersBefore, Date.now < deadline { sleep(2) }
        XCTAssertGreaterThan(app.buttons.matching(NSPredicate(format: "label == %@", "Start")).count, timersBefore,
                             "no timer came back after tapping Yes")
        sleep(1)
        shot("05-timer-rendered")
    }
}
