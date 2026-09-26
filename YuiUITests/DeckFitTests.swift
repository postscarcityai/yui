import XCTest

/// An inline deck is as tall as the page showing, no more (TestFlight feedback
/// AK2rJFQ9Av0lJnR3D37jnus, build 96: "there's too much random white space here and
/// I would love for this component to look a little more similar to how it does on
/// the full screen version"). The pager had a fixed 380 to 440 pt frame, so a
/// four-line page sat over half a card of nothing. Here, on every page of a four-page
/// deck with a short page, a long one and points, the arrows sit right under the last
/// line, and the card grows and shrinks with the page. Demo account, no network.
/// Screenshots go to `YUI_SHOTS` when set.
final class DeckFitTests: XCTestCase {
    func testLight() throws { try run(appearance: "light", tag: "light") }
    func testDark() throws { try run(appearance: "dark", tag: "dark") }

    private let titles = ["Feel first", "What goes first", "On the board", "Taps and scroll"]

    private func run(appearance: String, tag: String) throws {
        let app = XCUIApplication()
        let shots = ProcessInfo.processInfo.environment["YUI_SHOTS"].map { URL(fileURLWithPath: $0) }
        func shot(_ name: String) {
            let s = XCUIScreen.main.screenshot()
            if let shots { try? s.pngRepresentation.write(to: shots.appending(path: "\(name)-\(tag).png")) }
            let a = XCTAttachment(screenshot: s)
            a.name = "\(name)-\(tag)"
            a.lifetime = .keepAlways
            add(a)
        }
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoDeckFit", "-appearance", appearance]
        app.launch()

        let full = app.buttons.matching(NSPredicate(format: "label == %@", "Full screen")).firstMatch
        XCTAssertTrue(full.waitForExistence(timeout: 15), "no inline deck")
        let next = app.buttons.matching(NSPredicate(format: "label == %@", "Next page")).firstMatch
        let prev = app.buttons.matching(NSPredicate(format: "label == %@", "Previous page")).firstMatch

        var gaps: [CGFloat] = []
        var tops: [CGFloat] = []  // header to arrows: the card's height, wherever the chat scrolled it
        for i in titles.indices {
            if i > 0 {
                XCTAssertTrue(next.waitForHittable(timeout: 4), "no Next arrow on page \(i)")
                next.tap()
            }
            let title = app.staticTexts.matching(NSPredicate(format: "label == %@", titles[i])).firstMatch
            XCTAssertTrue(title.waitForHittable(timeout: 4), "page \(i + 1) title not on screen")
            sleep(1)
            // The page's lowest line: every text between the deck's header and its arrows.
            let arrowTop = prev.frame.minY
            let screen = app.frame
            let lowest = app.staticTexts.allElementsBoundByIndex
                .map { $0.frame }
                .filter { $0.minY > full.frame.maxY && $0.maxY <= arrowTop + 1 && $0.width > 0
                    && $0.minX >= screen.minX && $0.maxX <= screen.maxX }  // not the pages beside it
                .map(\.maxY).max() ?? full.frame.maxY
            gaps.append(arrowTop - lowest)
            tops.append(arrowTop - full.frame.minY)
            shot("page\(i + 1)")
        }
        // Arrows right under the words: never half a card of nothing (it was ~250 pt).
        for (i, g) in gaps.enumerated() {
            XCTAssertLessThan(g, 64, "page \(i + 1): \(Int(g)) pt of empty card above the arrows")
        }
        // The card follows the page: the long page's card is taller than the short one's.
        XCTAssertGreaterThan(tops[1] - tops[0], 40, "the card did not grow for the long page")
        XCTAssertGreaterThan(tops[1] - tops[3], 20, "the card did not shrink back for a short page")
    }
}

fileprivate extension XCUIElement {
    func waitForHittable(timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if exists, isHittable { return true }
            usleep(200_000)
        }
        return exists && isHittable
    }
}
