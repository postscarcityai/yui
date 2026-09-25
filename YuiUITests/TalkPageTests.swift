import XCTest

/// Chat with a screen (YUI-62): a page is full screen with no composer, unless the
/// agent keeps one there with `>2 talk`. What you type on it lands in the chat with
/// a "From screen 2" chip that goes back to the page. Demo account, no network.
/// Screenshots go to `YUI_SHOTS`.
final class TalkPageTests: XCTestCase {
    func testComposerOnATalkPageOnly() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "wizard", "-appearance", "dark",
                               "-yuiThemeDemo", [
                                   "say Your week is on screen 2. Tell me what to change there.",
                                   ">2 card \"Week one\" body=\"Three runs, one long\"",
                                   ">2 list Runs Tue|Thu|\"Sat long\" +check",
                                   ">2 talk",
                                   ">3 list Notes \"Sleep more\"|\"New shoes\"",
                               ].joined(separator: "\\n"),
                               "-yuiDemoPrompt", "Plan my week"]
        app.launch()
        let composer = app.descendants(matching: .any)["composer"].firstMatch

        // The reply brings screen 3 forward: no talk there, so no composer.
        waitHittable(app.descendants(matching: .any)["page-3"].staticTexts["Sleep more"], "screen 3 never showed")
        waitSelected(app.buttons["page-tab-3"], "the reply did not bring screen 3 forward")
        waitGone(composer, "a composer on a screen the agent did not talk on")
        XCTAssertFalse(app.buttons["Settings"].isHittable, "the nav bar is on a screen")
        shot(app, "screen-3-no-composer")

        // Screen 2 talks: the composer is there, and it says what it is about.
        app.buttons["page-tab-2"].tap()
        waitSelected(app.buttons["page-tab-2"], "the dot does not go to screen 2")
        waitHittable(composer, "no composer on the talk screen")
        XCTAssertEqual(composer.placeholderValue, "About screen 2")
        XCTAssertFalse(app.buttons["Settings"].isHittable, "a talk screen is still full screen")
        shot(app, "screen-2-composer")

        composer.tap()
        composer.typeText("Swap Thursday for a swim")
        shot(app, "screen-2-typing")
        app.buttons["Send"].tap()
        // You stay on the screen you were talking about.
        waitSelected(app.buttons["page-tab-2"], "sending moved you off the screen")

        // The words land in the chat, marked with the screen they came from.
        app.buttons["page-tab-1"].tap()
        waitSelected(app.buttons["page-tab-1"], "the chat glyph does not go to the chat")
        waitHittable(app.staticTexts["Swap Thursday for a swim"], "the words did not land in the chat")
        let chip = app.buttons["screen-chip"].firstMatch
        waitHittable(chip, "no From screen 2 chip on the message")
        XCTAssertEqual(chip.label, "From screen 2")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '[yui]'")).firstMatch.exists,
                       "the tag shows in the bubble")
        shot(app, "chat-from-screen-2")

        // The chip goes back to the screen.
        chip.tap()
        waitSelected(app.buttons["page-tab-2"], "the chip does not go to screen 2")
        waitHittable(composer, "the composer left the talk screen")
    }

    // MARK: helpers

    private func shot(_ app: XCUIApplication, _ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "talk-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func waitSelected(_ e: XCUIElement, _ message: String) {
        let p = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "showing"), object: e)
        XCTAssertEqual(XCTWaiter.wait(for: [p], timeout: 8), .completed, message)
    }

    private func waitGone(_ e: XCUIElement, _ message: String) {
        let p = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false OR isHittable == false"), object: e)
        XCTAssertEqual(XCTWaiter.wait(for: [p], timeout: 6), .completed, message)
    }

    private func waitHittable(_ e: XCUIElement, _ message: String, timeout: TimeInterval = 20) {
        let p = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND isHittable == true"), object: e)
        XCTAssertEqual(XCTWaiter.wait(for: [p], timeout: timeout), .completed, message)
    }
}
