import XCTest

/// The group thread's bar (t_76b0a0cf, voice first): + T and the mic bottom right like the agent chat,
/// and a mic on the group's name field. Demo account with a demo group, no network; `-yuiPTTFake`
/// stands in for the mic. Shots go to `YUI_SHOTS` when set (dark first), always into the result bundle.
final class GroupBarTests: XCTestCase {
    func testGroupBarDark() throws { try bar("dark") }
    func testGroupBarLight() throws { try bar("light") }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func bar(_ appearance: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiDemoGroup", "-appearance", appearance,
                               "-yuiPTTFake", "Weekend long run plan"]
        app.launch()
        let mic = any(app, "group-mic"), type = any(app, "group-type"), attach = any(app, "group-attach")
        XCTAssertTrue(mic.waitForExistence(timeout: 30), "no mic in the group thread")
        XCTAssertTrue(type.exists, "no T in the group thread")
        XCTAssertTrue(attach.exists, "no + in the group thread")
        XCTAssertEqual(mic.frame.width, 58, accuracy: 1, "mic size")
        XCTAssertLessThan(attach.frame.minX, type.frame.minX, "+ is not left of T")
        XCTAssertLessThan(type.frame.minX, mic.frame.minX, "the mic is not bottom right")
        XCTAssertGreaterThan(mic.frame.maxX, app.frame.width - 40, "the mic is not in the corner")
        XCTAssertFalse(any(app, "group-field").exists, "the field shows at rest")
        shot("group-bar-\(appearance)-1-bar")

        // T opens the typing field.
        type.tap()
        XCTAssertTrue(any(app, "group-field").waitForExistence(timeout: 5), "T did not open the field")
        shot("group-bar-\(appearance)-2-typing")
    }

    /// The name fields can be said: the mic fills the name.
    func testNameMicDark() throws { try nameMic("dark") }
    func testNameMicLight() throws { try nameMic("light") }

    private func nameMic(_ appearance: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiDemoGroup", "-appearance", appearance,
                               "-yuiPTTFake", "Weekend long run"]
        app.launch()
        XCTAssertTrue(any(app, "group-settings").waitForExistence(timeout: 30), "no group settings button")
        any(app, "group-settings").tap()
        let name = app.textFields["group-settings-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10), "no name field")
        let mic = any(app, "group-settings-name-mic")
        XCTAssertTrue(mic.exists, "no mic on the name field")
        shot("group-bar-\(appearance)-3-name-field")
        mic.tap()
        sleep(1)
        mic.tap()
        var tries = 0
        while !((name.value as? String) ?? "").contains("Weekend long run"), tries < 20 { usleep(500_000); tries += 1 }
        XCTAssertTrue(((name.value as? String) ?? "").contains("Weekend long run"), "the mic did not fill the name")
        shot("group-bar-\(appearance)-4-name-said")
    }
}
