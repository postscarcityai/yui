import XCTest

/// Siri's links (YUI-253): Log my food lands on Basil's camera from any thread, and Start my workout lands in
/// Arnold's with the session asked for. Demo account (the starter crew), no network. `-yuiOpenURL` opens the
/// same link the intents hand to the app. Screenshots go to `YUI_SHOTS` when set, and always into the result bundle.
final class SiriLinkTests: XCTestCase {
    /// Started on Arnold's thread, Log my food still lands on Basil's camera: no chat first.
    func testLogMyFoodLandsOnBasilsCamera() throws {
        for appearance in ["light", "dark"] {
            let app = launch("arnold", "yui://snap?agent=basil", appearance)
            let snap = app.descendants(matching: .any)["snap-button"].firstMatch
            XCTAssertTrue(snap.waitForExistence(timeout: 20), "Log my food did not open the camera (\(appearance))")
            sleep(1)
            shot("log-my-food", appearance)
            app.buttons["snap-close"].tap()
            app.buttons["stage-record"].tap()
            XCTAssertFalse(app.descendants(matching: .any)["stage-you"].exists, "a message went out before the photo")
            app.terminate()
        }
    }

    /// Start my workout: Arnold's thread opens and the drawer's Start a workout words go out.
    func testStartMyWorkoutAsksArnold() throws {
        let app = launch("basil", "yui://agent/arnold/thread?workout=1", "light")
        let record = app.buttons["stage-record"]
        XCTAssertTrue(record.waitForExistence(timeout: 20), "no stage")
        sleep(6)
        record.tap()
        let said = app.staticTexts["Start today's workout"]
        let sent = said.waitForExistence(timeout: 15)
        if !sent { shot("start-my-workout-fail", "light") }
        XCTAssertTrue(sent, "nothing was sent to Arnold")
        shot("start-my-workout", "light")
    }

    private func launch(_ agent: String, _ url: String, _ appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoFirstLaunch", "-yuiAgent", agent,
                               "-appearance", appearance, "-yuiOpenURL", url, "-yuiDemoPickupAfter", "0.3",
                               "-yuiSnapFake", "/dev/null",
                               "-yuiDemoReply", "say \"Full body A, 40 minutes. Tap Start when ready.\"", "-yuiDemoReplyAfter", "1"]
        app.launch()
        return app
    }

    private func shot(_ name: String, _ appearance: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "siri-\(name)-\(appearance).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "siri-\(name)-\(appearance)"
        a.lifetime = .keepAlways
        add(a)
    }
}
