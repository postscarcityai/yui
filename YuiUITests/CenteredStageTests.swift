import XCTest

/// A plan's question sits in the middle of the full screen, not pinned under the
/// progress bar, and it is not a card inside the page (TestFlight feedback APXu3dFU,
/// 2026-09-26: "I don't see a reason that this card should be up towards the top...
/// prioritize vertically centering... not even a huge fan of cards within cards").
/// Walks every step kind a plan carries: page with a sketch, slide, choose, pick, form.
/// Demo account, no network. `YUI_SHOTS=<dir>` saves screenshots.
final class CenteredStageTests: XCTestCase {
    static let reply = [
        "plan \"The American Revolution\" review=false submit=\"Send it\"",
        "page \"Why it started\" body=\"Britain taxed the colonies to pay for a war. The colonists had no vote in Parliament.\"",
        "sketch frame=bubble",
        "row \"Taxes set in London\" +x",
        "row \"No say for the colonies\" +hi",
        "end",
        "slide \"Was Britain wrong to tax the colonies?\" 1-5 Fair|Unfair",
        "choose \"Who wrote the Declaration?\" Jefferson|Adams|Franklin",
        "pick \"Which were taxed?\" Tea|Paper|Sugar|Wool",
        "form \"About you\" name:text grade:1-12",
        "end",
    ].joined(separator: "\\n")

    func testDark() throws { try run(appearance: "dark") }
    func testLight() throws { try run(appearance: "light") }

    private func run(appearance: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-appearance", appearance, "-yuiThemeDemo", Self.reply]
        app.launch()

        let close = app.buttons["Close full screen"]
        if !close.waitForExistence(timeout: 12) {
            let open = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Open' AND label ENDSWITH 'full screen'")).firstMatch
            XCTAssertTrue(open.waitForExistence(timeout: 5), "the plan never showed")
            open.tap()
            XCTAssertTrue(close.waitForExistence(timeout: 5), "the plan did not open full screen")
        }
        let next = app.buttons["Next"]
        XCTAssertTrue(next.waitForExistence(timeout: 5), "no Next button")

        // Step 1, a page with its sketch: it reads, drawn in full.
        XCTAssertTrue(app.staticTexts["Step 1 of 5"].waitForExistence(timeout: 5))
        sleep(2)
        shot("1-page", appearance)
        XCTAssertTrue(app.staticTexts.matching(identifier: "story-title").firstMatch.exists, "the page has no headline")
        next.tap()

        // Step 2, the slide from the feedback screenshot: centered between the bars, no card.
        XCTAssertTrue(app.staticTexts["Step 2 of 5"].waitForExistence(timeout: 5))
        sleep(1)
        let s = shot("2-slide", appearance)
        let question = visibleText("Was Britain wrong to tax the colonies?", app)
        let slider = app.sliders.allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(question, "no slide question")
        XCTAssertNotNil(slider, "no slider")
        if let question, let slider {
            let top = app.staticTexts["Step 2 of 5"].frame.maxY
            let bottom = next.frame.minY
            let group = (question.frame.minY + slider.frame.maxY) / 2
            let room = (top + bottom) / 2
            XCTAssertLessThan(abs(group - room), (bottom - top) * 0.12,
                              "the question is not centered: group at \(Int(group)), room center \(Int(room))")
            assertNoCard(s, app: app, at: question.frame.midY, left: question.frame.minX)
        }
        next.tap()

        // Steps 3 to 5: each kind still renders and still answers.
        XCTAssertTrue(app.staticTexts["Step 3 of 5"].waitForExistence(timeout: 5))
        XCTAssertNotNil(visibleText("Who wrote the Declaration?", app), "no choose question")
        shot("3-choose", appearance)
        app.buttons["Jefferson"].tap()
        // A choose moves on by itself.
        XCTAssertTrue(app.staticTexts["Step 4 of 5"].waitForExistence(timeout: 5), "choose did not move on")
        XCTAssertNotNil(visibleText("Which were taxed?", app), "no pick question")
        app.buttons["Tea"].tap()
        shot("4-pick", appearance)
        next.tap()
        XCTAssertTrue(app.staticTexts["Step 5 of 5"].waitForExistence(timeout: 5))
        XCTAssertNotNil(visibleText("About you", app), "no form")
        let f = shot("5-form", appearance)
        if let t = visibleText("About you", app) { assertNoCard(f, app: app, at: t.frame.midY, left: t.frame.minX) }
    }

    private func visibleText(_ label: String, _ app: XCUIApplication) -> XCUIElement? {
        app.staticTexts.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex.first { $0.isHittable }
    }

    @discardableResult
    private func shot(_ name: String, _ tag: String) -> XCUIScreenshot {
        let s = XCUIScreen.main.screenshot()
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "centered-\(name)-\(tag).png"))
        }
        let a = XCTAttachment(screenshot: s)
        a.name = "centered-\(name)-\(tag)"
        a.lifetime = .keepAlways
        add(a)
        return s
    }

    /// Left of the words, where a card would paint its surface and border, the
    /// stage's own background shows, the same color as the screen's edge.
    private func assertNoCard(_ shot: XCUIScreenshot, app: XCUIApplication, at y: CGFloat, left: CGFloat,
                              file: StaticString = #filePath, line: UInt = #line) {
        guard let cg = shot.image.cgImage else { return XCTFail("no pixels", file: file, line: line) }
        let scale = CGFloat(cg.width) / app.frame.width
        let edge = sample(cg, x: 3 * scale, y: y * scale)
        for x in stride(from: 8, to: max(left - 3, 9), by: 3) {
            let inside = sample(cg, x: x * scale, y: y * scale)
            XCTAssertLessThan(distance(edge, inside), 0.04, "a card is drawn inside the page at x=\(Int(x))", file: file, line: line)
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
