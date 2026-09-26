import XCTest

/// Reply to a message (YUI-68, Chris's gesture map of 2026-09-25):
///   1. Hold a bubble or a card: reactions (agent's only) plus Reply, Copy, Select text.
///   2. The quote sits above the composer, x drops it.
///   3. Drag sideways, on a bubble or beside it: the next screen, never a reply.
///      Swipe to reply is gone (feedback AACnEo9w): it blocked the pager's drag.
/// Sent, the reply wears a chip; tapping it scrolls back to the original.
/// Demo account, no network (`-yuiLongThread` above `-yuiThreadRows`).
/// Screenshots go to `YUI_SHOTS` when set.
final class ReplyTests: XCTestCase {
    static let proposal = "Want me to set up Saturday? Squats 5x5 at 185, then a 20 minute tabata, done by 10."

    static var rows: [[String: Any]] { [
        ["id": "a0", "sender": "agent", "kind": "text", "created_at": "2026-09-25T10:00:00+00:00",
         "body": "```yui\n>2 list Groceries Milk|Eggs|Bread\nask \"Send the invite now?\" \"Yes, send\"|\"Not yet\"\n```"],
        ["id": "u1", "sender": "user", "kind": "text", "created_at": "2026-09-25T10:00:01+00:00", "body": "Sounds good"],
        ["id": "a1", "sender": "agent", "kind": "text", "created_at": "2026-09-25T10:00:02+00:00", "body": proposal],
    ] }

    func testLight() throws { try run("light") }
    func testDark() throws { try run("dark") }

    private func run(_ appearance: String) throws {
        let app = try launch(appearance)
        let bar = app.descendants(matching: .any)["reply-bar"]
        let bubble = text(app, Self.proposal)

        // 1. Hold the agent's bubble: the six reactions and Reply, Copy, Select text.
        bubble.press(forDuration: 0.8)
        let reply = app.buttons["react-reply"]
        XCTAssertTrue(reply.waitForExistence(timeout: 5), "no Reply in the hold menu")
        XCTAssertTrue(app.buttons["react-build it"].exists, "the reaction bar left the hold menu")
        XCTAssertTrue(app.buttons["react-copy"].exists && app.buttons["react-select"].exists)
        sleep(1)
        shot("reply-1-menu-\(appearance)")
        reply.tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 4), "Reply set no quote above the composer")
        XCTAssertTrue(bar.label.contains("Saturday"), "the quote is not the held message: \(bar.label)")
        sleep(1)
        shot("reply-2-quote-\(appearance)")

        // The x drops it. (The keyboard stays up for the words; holding the next bubble puts it away.)
        app.buttons["reply-cancel"].tap()
        XCTAssertTrue(bar.waitForNonExistence(timeout: 4), "x did not clear the quote")

        // Your own bubble: Reply, Copy, Select text, and no reactions.
        text(app, "Sounds good").press(forDuration: 0.8)
        XCTAssertTrue(reply.waitForExistence(timeout: 5), "no Reply on your own bubble")
        XCTAssertFalse(app.buttons["react-build it"].exists, "reactions on your own message")
        shot("reply-3-own-menu-\(appearance)")
        app.descendants(matching: .any)["reaction-dismiss"].firstMatch.tap()
        XCTAssertTrue(reply.waitForNonExistence(timeout: 4))

        // A card: hold its question, Reply quotes the question.
        text(app, "Send the invite now?").press(forDuration: 0.8)
        XCTAssertTrue(reply.waitForExistence(timeout: 5), "no Reply when holding a card")
        XCTAssertTrue(app.buttons["react-build it"].exists, "a card takes reactions too")
        reply.tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 4))
        XCTAssertTrue(bar.label.contains("Send the invite now?"), "a card quotes its question: \(bar.label)")
        app.buttons["reply-cancel"].tap()
        XCTAssertTrue(bar.waitForNonExistence(timeout: 4))
        keyboardDown(app, bubble)

        // 3. The background beside the agent's bubble pages to screen 2, it doesn't reply.
        let tab1 = app.buttons["page-tab-1"], tab2 = app.buttons["page-tab-2"]
        let f = bubble.frame
        let gutter = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: app.frame.width - 40, dy: f.midY))
        gutter.press(forDuration: 0.05, thenDragTo: gutter.withOffset(CGVector(dx: -220, dy: 0)))
        waitShowing(tab2, "a drag beside a bubble did not page to screen 2")
        XCTAssertFalse(bar.exists, "a drag beside a bubble set a reply")
        shot("reply-4-gutter-pages-\(appearance)")
        tab1.tap()
        waitShowing(tab1, "the Chat tab did not come back")

        // The bubble itself pages too: a left swipe on it sets no quote.
        swipeLeft(bubble)
        waitShowing(tab2, "a left swipe on a bubble did not page to screen 2")
        XCTAssertFalse(bar.exists, "a left swipe on a bubble set a reply")
        shot("reply-5-bubble-pages-\(appearance)")
        tab1.tap()
        waitShowing(tab1, "the Chat tab did not come back")
        waitHittable(bubble, "the proposal is not back on screen")

        // Reply to an old message, send, and the chip goes back to it.
        let old = text(app, "Message 2. Here's a longer answer")
        keyboardDown(app, bubble)
        for _ in 0..<12 where !old.isHittable {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)),
                       withVelocity: .fast, thenHoldForDuration: 0)
            sleep(1)
        }
        XCTAssertTrue(old.isHittable, "could not scroll up to Message 2")
        old.press(forDuration: 0.8)
        XCTAssertTrue(reply.waitForExistence(timeout: 5), "no Reply when holding an old message")
        reply.tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 4))
        XCTAssertTrue(bar.label.contains("Message 2"), "wrong quote: \(bar.label)")
        let field = app.textFields["composer"].exists ? app.textFields["composer"] : app.textViews["composer"]
        field.tap()
        field.typeText("Yes, that one")
        app.buttons["Send"].tap()
        XCTAssertTrue(bar.waitForNonExistence(timeout: 4), "the quote stayed after sending")
        let chip = app.buttons["reply-chip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "the sent reply has no quote chip")
        waitHittable(chip, "the sent reply is not on screen")
        XCTAssertFalse(old.isHittable, "Message 2 is still on screen: nothing to scroll back to")
        sleep(1)
        shot("reply-6-sent-chip-\(appearance)")
        chip.tap()
        XCTAssertTrue(app.descendants(matching: .any)["reply-original"].waitForExistence(timeout: 1.5),
                      "the original did not light up")
        shot("reply-7-original-\(appearance)")
        waitHittable(old, "tapping the chip did not scroll back to Message 2")
    }

    // MARK: Helpers

    private func launch(_ appearance: String, extra: [String] = []) throws -> XCUIApplication {
        let rowsFile = FileManager.default.temporaryDirectory.appending(path: "yui-reply-rows.json")
        try JSONSerialization.data(withJSONObject: Self.rows).write(to: rowsFile)
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "wizard", "-appearance", appearance,
                               "-yuiLongThread", "12", "-yuiThreadRows", rowsFile.path] + extra
        app.launch()
        let bubble = text(app, Self.proposal)
        XCTAssertTrue(bubble.waitForExistence(timeout: 15), "the thread never loaded")
        // A reply with a screen 2 line brings the page forward: back to the chat.
        let tab1 = app.buttons["page-tab-1"]
        if tab1.waitForExistence(timeout: 3), tab1.value as? String != "showing" { tab1.tap() }
        waitHittable(bubble, "the proposal is not on screen")
        return app
    }

    private func text(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// A finger on the bubble, dragged 160pt left.
    private func swipeLeft(_ e: XCUIElement) {
        let start = e.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -160, dy: 0)),
                    withVelocity: 600, thenHoldForDuration: 0.1)
    }

    /// The x keeps the keyboard up for the words: drag the thread down into it, then back to the newest.
    private func keyboardDown(_ app: XCUIApplication, _ bubble: XCUIElement) {
        guard app.keyboards.firstMatch.exists else { return }
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        top.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 4), "the keyboard stayed up")
        let jump = app.buttons["jump-to-bottom"]
        if jump.waitForExistence(timeout: 2) { jump.tap() }
        for _ in 0..<3 where !bubble.isHittable { app.scrollViews.firstMatch.swipeUp() }
        waitHittable(bubble, "the proposal is not back on screen")
    }

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

    private func waitShowing(_ e: XCUIElement, _ message: String) {
        let p = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "showing"), object: e)
        XCTAssertEqual(XCTWaiter.wait(for: [p], timeout: 6), .completed, message)
    }

    private func waitHittable(_ e: XCUIElement, _ message: String, timeout: TimeInterval = 6) {
        let p = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND isHittable == true"), object: e)
        XCTAssertEqual(XCTWaiter.wait(for: [p], timeout: timeout), .completed, message)
    }
}
