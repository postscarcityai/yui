import XCTest

/// Settings > About this build > Speed (YUI-102, spec yuigui/spec/PERF.md section 4):
/// on a Dev build (UI tests run the Xcode build, which counts) the switch sits under
/// About this build; on, the small overlay shows the last keystroke and the frame rate
/// over the chat. Typing a few keys fills in the keystroke number. Demo account, no
/// network. Screenshots go to `YUI_SHOTS` when set.
final class SpeedSwitchTests: XCTestCase {
    func testLight() throws { try run(appearance: "light") }

    func testDark() throws { try run(appearance: "dark") }

    private func run(appearance: String) throws {
        let app = XCUIApplication()
        let shots = ProcessInfo.processInfo.environment["YUI_SHOTS"].map { URL(fileURLWithPath: $0) }
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            if let shots { try? png.write(to: shots.appending(path: "\(name)-\(appearance).png")) }
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = "\(name)-\(appearance)"
            a.lifetime = .keepAlways
            add(a)
        }

        app.launchArguments = ["-yuiDemoAccount", "-yuiDemo", "-yuiSettings", "-yuiSettingsLarge",
                               "-appearance", appearance]
        app.launch()

        XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 15), "Settings did not open")
        let speed = app.switches["speedSwitch"]
        for _ in 0..<8 where !speed.isHittable { app.swipeUp() }
        XCTAssertTrue(speed.isHittable, "no Speed switch on a Dev build")
        // A launch argument would pin the default, so start from whatever the last run left.
        if speed.value as? String == "1" { speed.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        XCTAssertEqual(speed.value as? String, "0")
        speed.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(speed.value as? String, "1", "Speed did not turn on")
        shot("speed-switch")

        // Relaunch on the chat (the switch is saved): the overlay is there, and typing
        // gives it a keystroke time.
        app.terminate()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemo", "-appearance", appearance]
        app.launch()
        let field = app.descendants(matching: .any)["composer"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), "no composer")
        sleep(1)
        field.tap()
        field.typeText("hello")
        sleep(2)
        shot("speed-overlay")
        // Leave it off for the next run.
        UserDefaultsReset.speedOff(app)
    }
}

private enum UserDefaultsReset {
    /// Settings again, Speed off.
    static func speedOff(_ app: XCUIApplication) {
        app.terminate()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemo", "-yuiSettings", "-yuiSettingsLarge"]
        app.launch()
        _ = app.staticTexts["Appearance"].waitForExistence(timeout: 15)
        let speed = app.switches["speedSwitch"]
        for _ in 0..<8 where !speed.isHittable { app.swipeUp() }
        if speed.value as? String == "1" { speed.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
    }
}
