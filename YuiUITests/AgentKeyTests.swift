import XCTest

/// Per-agent model key (YUI-139 step 2g): Controls > Model says which key the agent runs on and lets the person
/// pick Yui's, Claude or ChatGPT for this agent alone. A provider with no key opens the key sheet for the agent.
/// Demo account, no network: `-yuiDemoNative` keeps the picks in memory. Screenshots go to `YUI_SHOTS`.
final class AgentKeyTests: XCTestCase {
    private var appearance: String { ProcessInfo.processInfo.environment["YUI_APPEARANCE"] ?? "light" }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = "agentkey-\(name)-\(appearance)"
        a.lifetime = .keepAlways
        add(a)
        guard let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] else { return }
        try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "agentkey-\(name)-\(appearance).png"))
    }

    func testPickWhichKeyOneAgentRunsOn() {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoFirstLaunch", "-yuiDemoNative", "-yuiAgent", "basil", "-yuiDrawer", "-appearance", appearance]
        app.launch()
        let tab = app.buttons["drawer-tab-agent"]
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "no Agent tab")
        tab.tap()
        let row = app.buttons["controls-model"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no Model row")
        row.tap()

        func choice(_ id: String) -> XCUIElement { app.buttons["model-key-\(id)"] }
        XCTAssertTrue(choice("yui").waitForExistence(timeout: 10), "no pick on Model")
        XCTAssertTrue(choice("yui").isSelected, "a new agent runs on Yui's key")
        XCTAssertTrue(choice("anthropic").exists && choice("openai").exists, "Claude and ChatGPT are not offered")
        XCTAssertTrue(choice("anthropic").label.contains("Add a key"), "Claude with no key should say Add a key")
        sleep(1)
        shot("1-model")

        // Claude has no key yet: the sheet opens for this agent alone, with Claude picked.
        choice("anthropic").tap()
        XCTAssertTrue(app.staticTexts["key-agent-only"].waitForExistence(timeout: 10), "the key sheet did not open for the agent")
        XCTAssertTrue(app.staticTexts["key-plan"].waitForExistence(timeout: 5), "the sheet did not start on Claude")
        sleep(1)
        shot("2-add-key")
        let field = app.secureTextFields["key-field"]
        field.tap()
        field.typeText("sk-ant-demo-9999")
        app.buttons["key-save"].tap()

        // Saved: the sheet closes and this agent is on Claude.
        XCTAssertTrue(choice("anthropic").waitForExistence(timeout: 10), "the sheet did not close")
        XCTAssertTrue(choice("anthropic").isSelected, "the agent did not switch to Claude")
        XCTAssertTrue(choice("anthropic").label.contains("9999"), "the key's last four are not shown")
        XCTAssertFalse(choice("yui").isSelected)
        sleep(1)
        shot("3-on-claude")

        // Back to Yui's key is one tap, the Claude key stays.
        choice("yui").tap()
        XCTAssertTrue(choice("yui").isSelected, "Yui's key did not come back")
        choice("anthropic").tap()
        XCTAssertTrue(choice("anthropic").isSelected, "a key they hold switches on one tap, no sheet")
        XCTAssertFalse(app.secureTextFields["key-field"].exists, "the sheet opened for a key they already hold")
    }
}
