import XCTest

/// A real body text style (YUI-196, TestFlight feedback: "big text should only be a
/// one liner or a headline", "we need a markdown reader in our new typography
/// system"). Long words on the stage read as body, one short line stays a
/// headline, and markdown is drawn, never shown as ** or #. Demo account, no
/// network. `YUI_SHOTS=<dir>` saves the screenshots (light and dark).
final class BodyTextTests: XCTestCase {
    static let long = "Chicken and rice, about 384 kcal. Sure on the chicken and rice. Less sure on oil used to cook."
    /// One paragraph, no blank lines, so it lands on one stage page. No apostrophes (launch args are plists).
    /// Chris's screenshot (t_988addea): a hyphen, bold and a label, all raw on the stage.
    static let markdown = "- **From now on:** every new post ships with a video like the Marketing Hours one instead of the audio read. If a video fails to build, the post gets audio as a backup so it never goes out with neither."

    func testALongSayReadsAsBodyLight() throws { try longSay("light") }
    func testALongSayReadsAsBodyDark() throws { try longSay("dark") }
    func testMarkdownIsDrawnLight() throws { try markdownStage("light") }
    func testMarkdownIsDrawnDark() throws { try markdownStage("dark") }
    func testAMarkdownListLight() throws { try markdownList("light") }
    func testAMarkdownListDark() throws { try markdownList("dark") }
    func testADeckPageAndAChartCaptionLight() throws { try deck("light") }
    func testADeckPageAndAChartCaptionDark() throws { try deck("dark") }

    private func longSay(_ appearance: String) throws {
        let app = launch(appearance, reply: "say \"\(Self.long)\"")
        send(app, "Chicken and a little bit of rice")
        let words = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'stage-line' AND label BEGINSWITH 'Chicken and rice'")).firstMatch
        XCTAssertTrue(words.waitForExistence(timeout: 15), "the answer never played")
        sleep(1)
        shot("long-say", appearance)
        // Body type: a paragraph this long fits in a few lines, not a wall of display type.
        XCTAssertLessThan(words.frame.height, 260, "the long line is still set at display size")
    }

    private func markdownStage(_ appearance: String) throws {
        let app = launch(appearance, reply: "say \"\(Self.markdown)\"")
        send(app, "Future posts and the 8 scheduled")
        let words = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'stage-line'")).firstMatch
        let played = words.waitForExistence(timeout: 15)
        sleep(1)
        shot("markdown", appearance)
        XCTAssertTrue(played, "the answer never played")
        let label = words.label
        XCTAssertFalse(label.contains("**"), "raw bold marks: \(label)")
        XCTAssertFalse(label.contains("##"), "raw heading marks: \(label)")
        XCTAssertFalse(label.hasPrefix("-"), "a lone hyphen: \(label)")
        XCTAssertTrue(label.hasPrefix("From now on: every new post"), label)
    }

    /// A heading, `Label: value` lines with a check and a cross, and a list (t_988addea, t_dbbf055c).
    private func markdownList(_ appearance: String) throws {
        let md = "## Video in every post\n**Publishing pipeline:** still makes audio\n**Technically possible:** yes ✅\n**Video in every post:** not yet ❌\n- Build the video\n- Post it with `publish`"
        // Plain markdown, as a model sends it, then a fence (a fence makes the demo a real thread row).
        let reply = (md + "\n```yui\nask \"Add it?\" Yes|No\n```").replacingOccurrences(of: "\n", with: "\\n")
        let app = launch(appearance, reply: reply)
        send(app, "Future posts and the 8 scheduled")
        let words = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'stage-line'")).firstMatch
        let played = words.waitForExistence(timeout: 15)
        sleep(1)
        shot("markdown-list", appearance)
        XCTAssertTrue(played, "the answer never played")
        let label = words.label
        XCTAssertFalse(label.contains("**"), "raw bold marks: \(label)")
        XCTAssertFalse(label.contains("##"), "raw heading marks: \(label)")
        XCTAssertTrue(label.contains("Publishing pipeline: still makes audio"), label)
    }

    private func deck(_ appearance: String) throws {
        let reply = [
            "deck \"What changed\"",
            "page \"Body text\" body=\"\(Self.long) Every part of the app that used to shout now reads like a person talking.\"",
            "page \"Pace\" body=\"The chart shows how the answers slowed down once the long text got its own style.\"",
            "chart bar \"Lines per answer\" x=Before|After y=9|4",
            "end",
        ].joined(separator: "\\n")
        let app = launch(appearance, reply: reply)
        send(app, "Show me the change")
        XCTAssertTrue(app.staticTexts["Body text"].waitForExistence(timeout: 15) || app.descendants(matching: .any)["stage-line"].waitForExistence(timeout: 5),
                      "the deck never played")
        sleep(2)
        shot("deck-page", appearance)
        let next = app.buttons["stage-next"]
        if next.waitForExistence(timeout: 3) {
            next.tap()
            sleep(2)
            shot("chart-text", appearance)
            // YUI-205: the last page's Back home pill once made the whole stage wider than the phone.
            XCTAssertGreaterThan(app.buttons["stage-menu"].frame.minX, 8, "the stage is wider than the screen on the last page")
            XCTAssertLessThan(app.buttons["stage-new-chat"].frame.maxX, app.windows.firstMatch.frame.width - 8,
                              "the stage is wider than the screen on the last page")
        }
    }

    private func launch(_ appearance: String, reply: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "yui",
                               "-appearance", appearance, "-yuiDemoReply", reply,
                               "-yuiDemoPickupAfter", "0.5", "-yuiDemoReplyAfter", "3.5"]
        app.launch()
        return app
    }

    private func send(_ app: XCUIApplication, _ words: String) {
        XCTAssertTrue(app.buttons["stage-type"].waitForExistence(timeout: 15), "no stage")
        app.buttons["stage-type"].tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(words)
        app.buttons["stage-send-text"].tap()
    }

    private func shot(_ name: String, _ appearance: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "body-\(name)-\(appearance).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "body-\(name)-\(appearance)"
        a.lifetime = .keepAlways
        add(a)
    }
}
