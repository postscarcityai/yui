import XCTest

/// Agents draw (YUI-84, TestFlight feedback ALUttyXBpVz3lQ3wUPtf9js on build 96: "draw
/// a little window that has certain things crossed out and other things highlighted").
/// `-yuiDemoPages` seeds a deck whose "No card or feedback ids" page is drawn as a chat
/// bubble, the id struck and the plain words highlighted, a page that is only a phone
/// drawing, and a window sketch on its own in the chat. Every drawn row is there with its
/// marks as its accessibility value, in the chat and full screen.
/// Demo account, no network. Screenshots go to `YUI_SHOTS` when set.
final class SketchTests: XCTestCase {
    func testLight() throws { try run(appearance: "light", tag: "light") }
    func testDark() throws { try run(appearance: "dark", tag: "dark") }
    func testAX3() throws { try run(appearance: "light", type: "UICTContentSizeCategoryAccessibilityXL", tag: "ax3") }

    private func run(appearance: String, type: String? = nil, tag: String) throws {
        let app = XCUIApplication()
        let shots = ProcessInfo.processInfo.environment["YUI_SHOTS"].map { URL(fileURLWithPath: $0) }
        func shot(_ name: String) {
            let s = XCUIScreen.main.screenshot()
            if let shots { try? s.pngRepresentation.write(to: shots.appending(path: "sketch-\(name)-\(tag).png")) }
            let a = XCTAttachment(screenshot: s)
            a.name = "sketch-\(name)-\(tag)"
            a.lifetime = .keepAlways
            add(a)
        }
        func row(_ label: String) -> XCUIElement {
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == 'sketch-row' AND label == %@", label)).firstMatch
        }
        /// The row is drawn (on screen, not only in the tree) and carries its marks.
        func assertRow(_ label: String, _ marks: String, _ where_: String, file: StaticString = #filePath, line: UInt = #line) {
            let r = row(label)
            XCTAssertTrue(r.waitForExistence(timeout: 5), "\(where_): no drawn row \"\(label)\"", file: file, line: line)
            XCTAssertTrue(r.isHittable, "\(where_): \"\(label)\" is not on screen", file: file, line: line)
            XCTAssertEqual(r.value as? String ?? "", marks, "\(where_): marks on \"\(label)\"", file: file, line: line)
        }

        var args = ["-yuiDemoAccount", "-yuiDemoPages", "-appearance", appearance]
        if let type { args += ["-UIPreferredContentSizeCategoryName", type] }
        app.launchArguments = args
        app.launch()

        /// The chat opens at its newest message: look up first, then back down.
        /// Scrolls the thread from its left margin: a swipe on the deck card would scroll its page instead.
        func scroll(up: Bool) {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: up ? 0.7 : 0.35))
            from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: up ? 0.35 : 0.7)))
        }
        func reveal(_ e: XCUIElement, below: Bool = false) {
            for _ in 0..<10 where !(e.exists && e.isHittable) { scroll(up: below) }
            for _ in 0..<10 where !(e.exists && e.isHittable) { scroll(up: !below) }
            sleep(1)
        }
        /// This deck's own Full screen button: the nearest one above the drawing.
        func fullButton(above e: XCUIElement) -> XCUIElement? {
            app.buttons.matching(NSPredicate(format: "label == %@", "Full screen")).allElementsBoundByIndex
                .filter { $0.isHittable && $0.frame.minY < e.frame.minY }.max { $0.frame.minY < $1.frame.minY }
        }

        // In the chat: the deck's first page on its card, the bubble before and after.
        let struck = row("Parked YUI-83 (t_2f464301) in the backlog")
        XCTAssertTrue(struck.waitForExistence(timeout: 15), "the drawn page never reached the chat")
        reveal(struck)
        assertRow("Parked YUI-83 (t_2f464301) in the backlog", "crossed out", "chat page")
        assertRow("Parked the drawing card in the backlog", "highlighted", "chat page")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == 'BEFORE' OR label == 'AFTER'")).count, 2,
                       "the pair is not labelled Before and After")
        shot("chat-page")

        // The window sketch alone in the chat, on a card: struck and greyed, a filler bar.
        let ids = row("YUI-78 ALUttyXBpVz3")
        reveal(ids, below: true)
        assertRow("YUI-78 ALUttyXBpVz3", "crossed out, greyed", "chat sketch")
        assertRow("Hold menu fits", "highlighted", "chat sketch")
        XCTAssertTrue(row("Blank line").exists, "the filler row is missing")
        shot("chat-window")

        // Full screen: the page is the screen and the drawing is its picture.
        reveal(struck)
        let full = try XCTUnwrap(fullButton(above: struck), "no Full screen button on the drawn deck")
        full.tap()
        let title = app.staticTexts.matching(NSPredicate(format: "identifier == 'story-title' AND label == %@",
                                                         "No card or feedback ids")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "the drawn page did not open full screen")
        sleep(3)
        assertRow("Parked YUI-83 (t_2f464301) in the backlog", "crossed out", "story page 1")
        assertRow("Parked the drawing card in the backlog", "highlighted", "story page 1")
        shot("story-page1")

        // Page 2: a phone drawn with its buttons, one struck, one highlighted.
        app.swipeLeft()
        sleep(3)
        assertRow("Got it", "crossed out, button", "story page 2")
        assertRow("Install", "highlighted, button", "story page 2")
        assertRow("Build 97 is ready", "", "story page 2")
        shot("story-page2")
    }
}
