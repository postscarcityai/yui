import XCTest

/// Your own key (YUI-139 step 2e): the limit card's button opens Settings at Your model key, which says
/// plainly that a chat plan can't pay for another app, links to where each provider makes a key, and
/// names the other road (add Yui inside Claude or ChatGPT). Add agent carries a quiet "Bring your own key".
/// Demo account, no network: `-yuiDemoNative` serves Claude, ChatGPT and OpenRouter. Screenshots go to `YUI_SHOTS`.
final class OwnKeyTests: XCTestCase {
    static let reply = """
    say "Those are your 100 free turns for this month. They come back on October 1, or add your own model key in Settings to keep going now."
    card "Free turns used" body="100 a month on Yui. Your own key has no limit." cta="Add my key" url=yui://settings/key
    """

    private var appearance: String { ProcessInfo.processInfo.environment["YUI_APPEARANCE"] ?? "light" }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = "ownkey-\(name)-\(appearance)"
        a.lifetime = .keepAlways
        add(a)
        guard let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] else { return }
        try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "ownkey-\(name)-\(appearance).png"))
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemo", "-yuiDemoNative", "-appearance", appearance] + extra
        app.launch()
        return app
    }

    func testTheLimitCardOpensTheKeySheet() {
        let app = launch(["-yuiDemoReply", Self.reply.replacingOccurrences(of: "\n", with: "\\n")])
        let field = app.descendants(matching: .any)["composer"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no composer")
        field.tap()
        field.typeText("Plan my week")
        app.buttons["Send"].tap()
        let open = app.buttons["Add my key"]
        XCTAssertTrue(open.waitForExistence(timeout: 20), "no key button on the limit card")
        sleep(1)
        shot("1-limit-card")

        open.tap()
        let left = app.staticTexts["key-left"]
        XCTAssertTrue(left.waitForExistence(timeout: 10), "Settings did not open at Your model key")
        XCTAssertEqual(left.label, "Yui and your crew have 69 of 100 free turns left this month. Add your own key to keep going with no limit.")
        XCTAssertTrue(app.secureTextFields["key-field"].isHittable, "the key field is off screen")
        XCTAssertFalse(app.buttons["key-save"].isEnabled, "Save works with no key")
        XCTAssertTrue(app.staticTexts["key-other-road"].exists, "no other road")
        sleep(1)
        shot("2-settings-key")

        // Claude: the plan line and the link to make a key.
        app.buttons["key-provider"].tap()
        app.buttons["Claude"].tap()
        let plan = app.staticTexts["key-plan"]
        XCTAssertTrue(plan.waitForExistence(timeout: 5), "no plan line for Claude")
        XCTAssertEqual(plan.label, "A Claude Pro or Max plan can't pay for another app. Only an API key can.")
        XCTAssertTrue(app.descendants(matching: .any)["key-make"].exists, "no link to make a key")
        sleep(1)
        shot("3-claude")
    }

    func testAddAgentHasAQuietBringYourOwnKey() {
        let app = launch(["-yuiDemoFirstLaunch", "-yuiAgents", "-yuiAddAgent"])
        let bring = app.buttons["bring-own-key"]
        XCTAssertTrue(bring.waitForExistence(timeout: 20), "no Bring your own key in Add agent")
        sleep(1)
        shot("4-add-agent")
        bring.tap()
        XCTAssertTrue(app.secureTextFields["key-field"].waitForExistence(timeout: 10), "the sheet did not open")
        sleep(1)
        shot("5-sheet")
    }
}
