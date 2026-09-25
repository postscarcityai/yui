import XCTest

/// Full-screen pages tell a story (YUI-82, TestFlight feedback ALUttyXBpVz3lQ3wUPtf9js
/// on build 96: "bare minimum effort... we're telling a story visually with the letters").
/// The build 96 card-it answer folds, and Read as pages opens it on the stage: the page
/// is the whole screen with no card drawn on it, one idea per page, and no title or
/// line stops mid-sentence. The build-ready deck opens full screen the same way.
/// Demo account, no network. Screenshots go to `TEST_RUNNER_YUI_SHOTS` when set.
final class StoryPagesTests: XCTestCase {
    func testLight() throws { try run(appearance: "light", tag: "light") }
    func testDark() throws { try run(appearance: "dark", tag: "dark") }
    func testAX3() throws { try run(appearance: "light", type: "UICTContentSizeCategoryAccessibilityXL", tag: "ax3") }

    /// The folded message, word for word (ChatView.cardedAnswer, without the list marks).
    private let source = """
        I've carded it as YUI-81 (backlog), with the other Yui app cards, next to YUI-79 (no text bombs). \
        It fixes the pages in the "What's in build" deck: \
        Each page gets a real title, like "Hold menu fits". \
        Each page says in plain words what you can do now. No card or feedback ids. \
        Changes that only matter to people building on Yui share one page. \
        Nothing gets cut off mid-sentence. \
        It's done when a test run on build 96's changes gives pages you can read at a glance, with before and after shown. \
        It waits its turn like any other backlog card.
        """

    private func run(appearance: String, type: String? = nil, tag: String) throws {
        let app = XCUIApplication()
        let shots = ProcessInfo.processInfo.environment["YUI_SHOTS"].map { URL(fileURLWithPath: $0) }
        func shot(_ name: String) -> XCUIScreenshot {
            let s = XCUIScreen.main.screenshot()
            if let shots { try? s.pngRepresentation.write(to: shots.appending(path: "\(name)-\(tag).png")) }
            let a = XCTAttachment(screenshot: s)
            a.name = "\(name)-\(tag)"
            a.lifetime = .keepAlways
            add(a)
            return s
        }
        func pageLabel() -> String? {
            let e = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Page ' AND label CONTAINS ' of '")).firstMatch
            return e.exists ? e.label : nil
        }
        func pageCount() -> Int {
            guard let l = pageLabel(), let n = l.split(separator: " ").last.flatMap({ Int($0) }) else { return 0 }
            return n
        }
        /// The words drawn on the page showing now: its headline, then its body.
        func shownWords() -> [String] {
            ["story-title", "story-body", "story-point"].flatMap { id in
                app.staticTexts.matching(identifier: id).allElementsBoundByIndex.filter { $0.isHittable }.map { $0.label }
            }
        }

        var args = ["-yuiDemoAccount", "-yuiDemoPages", "-appearance", appearance]
        if let type { args += ["-UIPreferredContentSizeCategoryName", type] }
        app.launchArguments = args
        app.launch()

        // The fold: Read as pages opens the stage.
        let read = app.buttons["Read as pages"]
        XCTAssertTrue(read.waitForExistence(timeout: 15), "the card-it answer did not fold")
        read.tap()
        let close = app.buttons["Close full screen"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the pages did not open")
        sleep(2)
        let first = shot("fold-page1")
        assertNoCardChrome(first, app: app, "the fold's first page")

        // Walk every page: one idea each, words from the message, nothing cut mid-sentence.
        let n = pageCount()
        XCTAssertGreaterThanOrEqual(n, 5, "the list should be a page per idea, not three pages: \(n)")
        var seen: [String] = []
        for i in 1...max(n, 1) {
            XCTAssertEqual(pageLabel(), "Page \(i) of \(n)")
            let words = shownWords()
            XCTAssertFalse(words.isEmpty, "page \(i) shows no story text")
            for w in words {
                assertWhole(w, page: i)
                XCTAssertFalse(seen.contains(w), "page \(i) repeats \(w)")
            }
            seen += words
            if i == 2 || i == 5 { _ = shot("fold-page\(i)") }
            if i < n {
                app.swipeLeft()
                let next = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Page \(i + 1) of \(n)"),
                                                     object: app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Page '")).firstMatch)
                XCTAssertEqual(XCTWaiter.wait(for: [next], timeout: 4), .completed, "the swipe did not reach page \(i + 1)")
                sleep(1)
            }
        }
        // Every idea in the message made it onto a page.
        for idea in ["Hold menu fits", "No card or feedback ids", "share one page", "mid-sentence"] {
            XCTAssertTrue(seen.contains { $0.contains(idea) }, "no page carries \(idea)")
        }
        close.tap()
        XCTAssertTrue(read.waitForHittable(timeout: 4), "not back in the chat")

        // The build-ready deck: full screen from its own button, the same stage look.
        let full = app.buttons.matching(NSPredicate(format: "label == %@", "Full screen")).allElementsBoundByIndex.last
        XCTAssertNotNil(full)
        app.swipeUp()
        full?.tap()
        sleep(3)
        let deck = shot("build-page1")
        let title = app.staticTexts.matching(NSPredicate(format: "identifier == 'story-title' AND label == %@",
                                                         "The hold menu fits any message")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "the build deck's page title is not the headline")
        assertNoCardChrome(deck, app: app, "the build deck")
        app.swipeLeft()
        sleep(1)
        _ = shot("build-page2")
    }

    /// A line on a page is the message's own words, and when it stops short it stops
    /// after a whole clause: never "with the…".
    private func assertWhole(_ label: String, page: Int, file: StaticString = #filePath, line: UInt = #line) {
        let cut = label.hasSuffix("…")
        let core = cut ? String(label.dropLast()) : label
        guard let r = source.range(of: core) else {
            XCTFail("page \(page) says words the message did not: \(label)", file: file, line: line)
            return
        }
        let after = source[r.upperBound...].first
        if let after, after.isLetter || after.isNumber {
            XCTFail("page \(page) cuts a word: \(label)", file: file, line: line)
        }
        if cut, let last = core.last, !",.;:!?".contains(last), let after, !",.;:!?".contains(after) {
            XCTFail("page \(page) stops mid-sentence: \(label)", file: file, line: line)
        }
    }

    /// The stage's own background runs edge to edge behind the page: a card would
    /// paint its surface a few points in from the edge, around the words.
    private func assertNoCardChrome(_ shot: XCUIScreenshot, app: XCUIApplication, _ what: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        guard let cg = shot.image.cgImage else { return XCTFail("no pixels", file: file, line: line) }
        let scale = CGFloat(cg.width) / app.frame.width
        let edge = sample(cg, x: 3 * scale, y: app.frame.midY * scale)
        for y in stride(from: app.frame.height * 0.3, through: app.frame.height * 0.75, by: app.frame.height * 0.15) {
            // Inside a card's edge (16 pt margin + a few), left of any words (24 pt margin).
            let inside = sample(cg, x: 20 * scale, y: y * scale)
            XCTAssertLessThan(distance(edge, inside), 0.04, "\(what) draws a card at y=\(Int(y))", file: file, line: line)
        }
    }

    private func sample(_ cg: CGImage, x: CGFloat, y: CGFloat) -> [CGFloat] {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: -x, y: y - CGFloat(cg.height) + 1, width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return px.prefix(3).map { CGFloat($0) / 255 }
    }

    private func distance(_ a: [CGFloat], _ b: [CGFloat]) -> CGFloat {
        zip(a, b).map { abs($0 - $1) }.max() ?? 1
    }
}

private extension XCUIElement {
    func waitForHittable(timeout: TimeInterval) -> Bool {
        let e = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: self)
        return XCTWaiter.wait(for: [e], timeout: timeout) == .completed
    }
}
