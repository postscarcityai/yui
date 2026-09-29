import XCTest

/// Hold the Yui icon (YUI-191): a quick action lands in that agent's thread and does what a
/// drawer shortcut does. `-yuiDemoQuickAction <agent>/<item>` sends the tap a held icon sends
/// (a UI test can't hold the icon). Demo account, no network. Shots go to `YUI_SHOTS`.
final class QuickActionTests: XCTestCase {
    private func launch(_ tap: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoHome", "-yuiAgent", "yui", "-appearance", "light",
                               "-yuiDemoQuickAction", tap, "-yuiDemoReply", "say On it."]
        app.launch()
        return app
    }

    /// Basil's "Log food" ends in a space: Basil's thread opens with the words in the composer.
    func testLogFoodLandsInBasilsThreadWithTheComposerReady() {
        let app = launch("demo-basil/log-food/Log food: ")
        // The record's composer, or the full screen's T field: either holds the words.
        let has = NSPredicate(format: "value CONTAINS 'Log food:'")
        let field = app.descendants(matching: .any).matching(has).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the words are not in a composer")
    }

    /// A shortcut with no trailing space sends: its words are the person's message in Basil's thread.
    func testAShortcutWithCompleteWordsIsSent() {
        let app = launch("demo-basil/plan/Plan my meals")
        let ok = app.staticTexts["Plan my meals"].firstMatch.waitForExistence(timeout: 20)
        XCTAssertTrue(ok, "the words were not sent")
    }

    /// The real thing: leave the app, hold its icon on the home screen, Basil's "Log food" is there.
    func testHoldingTheIconShowsLogFood() {
        // Log food was the last one used, so it leads the icon menu.
        let app = launch("demo-basil/log-food/Log food: ")
        let composer = app.textFields["composer"].exists ? app.textFields["composer"] : app.textViews["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        sleep(2)
        // Keyboard down so the menu shot is clean.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        sleep(1)
        XCUIDevice.shared.press(.home)
        let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let icon = home.icons["Yui"]
        XCTAssertTrue(icon.waitForExistence(timeout: 10), "no Yui icon on the home screen")
        icon.press(forDuration: 1.5)
        let item = home.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Log food")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "Log food is not on the icon menu")
        sleep(1)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "icon-hold-menu.png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "icon-hold-menu"; a.lifetime = .keepAlways
        add(a)
        // The tap on it comes back to Basil's thread with the words ready.
        item.tap()
        let field = app.textFields["composer"].exists ? app.textFields["composer"] : app.textViews["composer"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        let x = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS 'Log food:'"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [x], timeout: 20), .completed, "the icon tap did not fill the composer")
    }
}
