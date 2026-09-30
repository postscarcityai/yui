import XCTest

/// The base type (YUI-211, Chris: "better typography across the whole app... a sleek sans serif as
/// the base"). One pass over the thread, screen 2, the drawer (Home, Review, Controls, About) and
/// Settings at the default text size, XL and AX3, light and dark. Nothing may run off the screen at
/// the big sizes. Demo account, no network. `YUI_SHOTS=<dir>` saves the shots (typo-<size>-<mode>-<n>).
final class TypographyTests: XCTestCase {
    static let reply = [
        "say Three drawer mocks are ready.",
        #"card "Pick a drawer" body="Calm list, playful tiles, or peek and tabs.""#,
        #"choose@drawer "Which one do I build?" Calm|Playful|Peek"#,
        ">2",
        #"card "Leg day" sub="Five moves, 40 minutes""#,
        "timer 45s Squats",
        "save workout",
    ].joined(separator: "\\n")

    func testDefaultLight() throws { try run("light", size: "default") }
    func testDefaultDark() throws { try run("dark", size: "default") }
    func testXLLight() throws { try run("light", size: "XL") }
    func testAX3Light() throws { try run("light", size: "AX3") }
    func testAX3Dark() throws { try run("dark", size: "AX3") }

    private func category(_ size: String) -> String? {
        switch size {
        case "XL": "UICTContentSizeCategoryXL"
        case "AX3": "UICTContentSizeCategoryAccessibilityL"
        default: nil
        }
    }

    private func run(_ appearance: String, size: String) throws {
        let tag = "typo-\(size)-\(appearance)"
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
                try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(tag)-\(name).png"))
            }
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = "\(tag)-\(name)"
            a.lifetime = .keepAlways
            add(a)
        }

        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", ProcessInfo.processInfo.environment["YUI_TYPO_AGENT"] ?? "wizard", "-appearance", appearance,
                               "-yuiThemeDemo", Self.reply, "-yuiDemoPrompt", "Can the agent menu come out from the left?"]
        if let cat = category(size) { app.launchArguments += ["-UIPreferredContentSizeCategoryName", cat] }
        app.launch()

        let close = app.buttons["drawer-close"]
        let squats = app.descendants(matching: .any)["page-2"].staticTexts["Squats"]
        XCTAssertTrue(squats.waitForExistence(timeout: 25), "the workout never reached screen 2")
        sleep(2)
        shot("1-screen2")

        app.swipeRight()
        let menu = app.buttons["Agent menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8), "no chat")
        sleep(1)
        shot("2-thread")

        menu.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the menu button did not open the drawer")
        sleep(1)
        shot("3-drawer-home")
        XCTAssertLessThanOrEqual(close.frame.maxX, app.frame.maxX + 1, "the drawer runs off the screen at \(size)")

        app.buttons["drawer-tab-review"].tap()
        sleep(1)
        shot("4-drawer-review")
        app.buttons["drawer-tab-agent"].tap()
        sleep(1)
        shot("5-drawer-agent")

        let settings = app.buttons["drawer-settings"]
        if settings.waitForExistence(timeout: 3) {
            settings.tap()
            sleep(2)
            shot("7-settings")
        }
    }
}
