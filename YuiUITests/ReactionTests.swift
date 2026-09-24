import XCTest

/// Reactions on the phone (YUI-49), against the live relay and a host whose
/// agent is a real model. Driven by `supabase/tests/reactions_e2e.py --sim
/// <udid>`, which runs the host and answers the handshake file below.
///
///   1. Ask; the agent proposes a plan.
///   2. Hold the proposal: the bar opens. Tap 👍: the badge lands on the bubble.
///   3. The agent gets the reaction as a turn and builds the plan.
///   4. Reopen (dark): the 👍 is still on the proposal, read back from the server.
///
/// Every launch needs its own FRESH refresh token (TEST_RUNNER_YUI_RTS, two).
final class ReactionTests: XCTestCase {
    func testThumbsUpBuildsIt() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rts = env["YUI_RTS"]?.split(separator: ",").map(String.init), rts.count >= 2,
              let user = env["YUI_USER"], let dir = env["YUI_SHOTS"] else {
            throw XCTSkip("run through supabase/tests/reactions_e2e.py --sim <udid>")
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
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let app = XCUIApplication()
        func launch(_ n: Int, _ appearance: String) -> XCUIElement {
            app.launchArguments = ["-yuiRefreshToken", rts[n], "-yuiUserID", user, "-appearance", appearance]
            app.launch()
            let allow = springboard.buttons["Allow"]
            if allow.waitForExistence(timeout: 6) { allow.tap() }
            let field = app.descendants(matching: .any).matching(
                NSPredicate(format: "placeholderValue == %@ OR label == %@", "Say something nice", "Say something nice")).firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 20))
            return field
        }
        let proposal = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Want me to set up Saturday")).firstMatch

        // 1. Ask; the agent proposes.
        let field = launch(0, "light")
        field.tap()
        field.typeText("Saturday workout?")
        app.buttons["Send"].tap()
        XCTAssertTrue(proposal.waitForExistence(timeout: 90), "no proposal from the agent")
        app.swipeDown()  // keyboard away
        sleep(1)

        // 2. Hold it: the bar. Tap 👍.
        proposal.press(forDuration: 0.8)
        let thumbs = app.buttons["react-build it"]
        XCTAssertTrue(thumbs.waitForExistence(timeout: 5), "no reaction bar after a long press")
        XCTAssertTrue(app.buttons["react-priority"].exists && app.buttons["react-not sure"].exists)
        sleep(1)
        shot("05-e2e-bar-light")
        thumbs.tap()
        func reacted(_ secs: TimeInterval) -> Bool {
            let end = Date.now.addingTimeInterval(secs)
            repeat {
                if (proposal.value as? String)?.contains("Reacted 👍") == true { return true }
                usleep(300_000)
            } while Date.now < end
            return false
        }
        XCTAssertTrue(reacted(5), "no 👍 on the bubble after the tap")
        XCTAssertFalse(thumbs.exists, "the bar stayed open")
        shot("06-e2e-reacted-light")

        // 3. The agent answers the reaction (the driver says when it's in the thread).
        try? Data().write(to: shots.appending(path: "need-reply"))
        let done = shots.appending(path: "reply-ok")
        let end = Date.now.addingTimeInterval(300)
        while !FileManager.default.fileExists(atPath: done.path), Date.now < end { sleep(1) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: done.path), "the agent never answered the 👍")
        sleep(4)
        app.swipeUp()
        sleep(1)
        shot("07-e2e-agent-built-it-light")
        app.terminate()

        // 4. Reopen in dark: the badge comes back from the server.
        _ = launch(1, "dark")
        XCTAssertTrue(proposal.waitForExistence(timeout: 20))
        XCTAssertTrue(reacted(10), "the 👍 did not come back after reopening")
        // The plan's screens push the proposal up under the bar: scroll back to it.
        for _ in 0..<3 where !proposal.isHittable || proposal.frame.minY < 140 { app.scrollViews.firstMatch.swipeDown() }
        sleep(1)
        shot("08-e2e-reopened-dark")
        proposal.press(forDuration: 0.8)
        XCTAssertTrue(thumbs.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["react-remove"].exists, "a reacted bubble offers Remove")
        sleep(1)
        shot("09-e2e-bar-dark")
        // Close by tapping the dimmed thread, clear of the bar and the menu.
        XCTAssertTrue(app.descendants(matching: .any)["reaction-dismiss"].firstMatch.exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.96)).tap()
        sleep(1)
        XCTAssertFalse(thumbs.exists, "the bar stayed open")
        XCTAssertEqual(proposal.value as? String, "Reacted 👍, build it", "closing the bar changed the reaction")
    }
}
