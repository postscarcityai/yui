import XCTest

/// The timer on the lock screen (YUI-30): start a Tabata, leave the app, and it
/// keeps counting in the Dynamic Island and on the lock screen; Pause there
/// pauses the timer in the app. Demo account, no network. Screenshots go to
/// `TEST_RUNNER_YUI_SHOTS` when set, and always into the result bundle.
final class LiveActivityTests: XCTestCase {
    func testTimerOnTheLockScreenAndInTheIsland() throws {
        try run(appearance: "dark", agent: "coach")
    }

    func testLight() throws {
        try run(appearance: "light", agent: "wizard")
    }

    private func run(appearance: String, agent: String) throws {
        let shots = ProcessInfo.processInfo.environment["YUI_SHOTS"].map { URL(fileURLWithPath: $0) }
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            if let shots { try? png.write(to: shots.appending(path: "\(appearance)-\(name).png")) }
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = "\(appearance)-\(name)"
            a.lifetime = .keepAlways
            add(a)
        }

        let app = XCUIApplication()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", agent, "-appearance", appearance,
                               "-yuiThemeDemo", StageTests.reply]
        app.launch()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 15), "the +auto timer is not running")
        sleep(2)
        shot("1-app")

        // Home: the timer rides in the Dynamic Island.
        XCUIDevice.shared.press(.home)
        sleep(3)
        shot("2-island-compact")
        // Long-press the island: the expanded view with the buttons.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.025)).press(forDuration: 1.2)
        sleep(2)
        shot("3-island-expanded")

        // Lock, wake: the lock screen shows it, still counting.
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(2)
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        // First time only: iOS asks whether Yui may keep Live Activities on the lock screen.
        // It asks again ("continue to allow?") once one has been up a while.
        for name in ["Allow", "Always Allow"] {
            let allow = springboard.buttons[name]
            if allow.waitForExistence(timeout: 3) { allow.tap() }
        }
        sleep(2)
        shot("4-lock-screen")
        // Across a phase change with the phone locked: the rounds keep advancing.
        sleep(12)
        shot("5-lock-screen-later")

        // Pause from the lock screen, and the app's timer is paused.
        let pause = springboard.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "no Pause on the lock screen")
        pause.tap()
        XCTAssertTrue(springboard.buttons["Resume"].waitForExistence(timeout: 8), "Pause did not take")
        sleep(1)
        shot("6-lock-screen-paused")

        // End from the lock screen: it leaves, and the timer stays paused in the app.
        springboard.buttons["End timer"].tap()
        XCTAssertTrue(springboard.buttons["Resume"].waitForNonExistence(timeout: 8), "End did not take it off")
        app.activate()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 15), "the app's timer is not paused")
        shot("7-app-paused")
    }
}
