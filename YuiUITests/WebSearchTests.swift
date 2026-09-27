import XCTest

/// Web search (YUI-142): a native agent answers with its sources as cards, and when
/// the free searches for the month are used up, one card invites the person to add
/// their own Firecrawl key. Its button opens Settings at Web search, where the key is
/// typed (never in chat). Demo account, no network: `-yuiDemoNative` makes Yui native
/// with 50 of 50 searches used. Screenshots go to `YUI_SHOTS` when set.
final class WebSearchTests: XCTestCase {
    /// What the runtime writes: the answer, a source card, then the invite (runtime/src/search.ts).
    static let reply = """
    say "The Knicks open the season on October 21, at home against Boston. I went from memory, the free searches are used up this month."
    card "NBA Schedule 2026-27 - ESPN" sub="espn.com" cta=Read url="https://www.espn.com/nba/schedule"
    card "Free web searches used" body="Yui looks up 50 things a month for you for free. Add your own Firecrawl key in Settings and lookups have no limit." cta="Open Settings" url=yui://settings/search
    """

    private var appearance: String { ProcessInfo.processInfo.environment["YUI_APPEARANCE"] ?? "light" }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = "search-\(name)-\(appearance)"
        a.lifetime = .keepAlways
        add(a)
        guard let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] else { return }
        try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "search-\(name)-\(appearance).png"))
    }

    func testTheInviteOpensSettingsAtWebSearch() {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemo", "-yuiDemoNative", "-appearance", appearance, "-yuiDemoReply",
                               Self.reply.replacingOccurrences(of: "\n", with: "\\n")]
        app.launch()
        let field = app.descendants(matching: .any)["composer"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no composer")
        field.tap()
        field.typeText("When do the Knicks play next?")
        app.buttons["Send"].tap()

        let open = app.buttons["Open Settings"]
        XCTAssertTrue(open.waitForExistence(timeout: 20), "no invite to add a Firecrawl key")
        XCTAssertTrue(app.buttons["Read"].exists, "no source card")
        XCTAssertFalse(app.secureTextFields.firstMatch.exists, "a key field in the chat")
        sleep(1)
        shot("1-answer-and-invite")

        open.tap()
        let left = app.staticTexts["search-left"]
        XCTAssertTrue(left.waitForExistence(timeout: 10), "Settings did not open at Web search")
        XCTAssertEqual(left.label, "Your 50 free web searches are used up this month. Add your own Firecrawl key and searches have no limit.")
        let key = app.secureTextFields["search-key-field"]
        XCTAssertTrue(key.waitForExistence(timeout: 5), "no key field in Settings")
        XCTAssertTrue(key.isHittable, "the key field is off screen")
        XCTAssertFalse(app.buttons["search-key-save"].isEnabled, "Save works with no key")
        sleep(1)
        shot("2-settings-web-search")
    }
}
