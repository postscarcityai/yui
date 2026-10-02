import XCTest

/// A Dismiss on a Needs you row (YUI-265, Chris Oct 1: "I see the same stuff over and over again"): the
/// row in the drawer's Review has a Dismiss next to it, a tap takes it off the list at once, the button's
/// count follows, and the host gets one quiet event (no echo in the chat). Demo account, no network.
/// Shots go to `YUI_SHOTS`, dark first.
final class DismissAskUITests: XCTestCase {
    static let reply = [
        "say Two things need you.",
        #"menu review@need-t_0a0b0c "Outside testers" sub="Do you have anyone to try Yui?""#,
        #"menu review@need-t_0a0b0d "Pick the shader look" sub="Three looks are ready""#,
    ].joined(separator: "\\n")

    func testDark() throws { try run("dark") }
    func testLight() throws { try run("light") }

    private func run(_ appearance: String) throws {
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
                try? png.write(to: URL(fileURLWithPath: dir).appending(path: "dismiss-\(appearance)-\(name).png"))
            }
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = "dismiss-\(appearance)-\(name)"
            a.lifetime = .keepAlways
            add(a)
        }
        let log = NSTemporaryDirectory() + "yui-265-\(UUID().uuidString).log"
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "wizard", "-appearance", appearance,
                               "-yuiThemeDemo", Self.reply, "-yuiDemoPrompt", "What needs me?", "-yuiDemoReply", "say Here we go.",
                               "-yuiEventLog", log]
        app.launch()

        let menu = app.buttons["Agent menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20), "no menu button")
        let waiting = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '2 waiting on you'"), object: menu)
        XCTAssertEqual(XCTWaiter.wait(for: [waiting], timeout: 20), .completed, "the two asks are not counted")
        menu.tap()
        XCTAssertTrue(app.buttons["drawer-close"].waitForExistence(timeout: 5))
        app.buttons["drawer-tab-review"].tap()
        let dismiss = app.buttons["review-dismiss-need-t_0a0b0c"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "no Dismiss on the review row")
        XCTAssertTrue(app.buttons["review-dismiss-need-t_0a0b0d"].exists, "no Dismiss on the second row")
        sleep(1)
        shot("1-review")

        dismiss.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["review-menu-need-t_0a0b0c"])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed, "the row stayed after Dismiss")
        XCTAssertTrue(app.buttons["review-menu-need-t_0a0b0d"].exists, "the other ask left too")
        XCTAssertTrue(app.staticTexts["1 thing is waiting on you"].exists, "the count did not follow")
        sleep(1)
        shot("2-after")

        let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        XCTAssertTrue(text.contains(#""dismissed":true"#) && text.contains(#""id":"need-t_0a0b0c""#), "no dismiss event: \(text)")
        XCTAssertFalse(text.contains("need-t_0a0b0d"), "the other ask sent something")
    }
}
