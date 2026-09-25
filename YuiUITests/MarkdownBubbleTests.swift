import XCTest

/// Markdown in agent bubbles (YUI-76): a /status answer and a sample with each
/// element draw without raw ** or backticks; the person's own bubble is as typed.
/// Demo account, no network. Screenshots go to `YUI_SHOTS` when set.
final class MarkdownBubbleTests: XCTestCase {
    func testLight() throws { try run(appearance: "light") }

    func testDark() throws { try run(appearance: "dark") }

    private func run(appearance: String) throws {
        let app = XCUIApplication()
        let shots = ProcessInfo.processInfo.environment["YUI_SHOTS"].map { URL(fileURLWithPath: $0) }
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            if let shots { try? png.write(to: shots.appending(path: "\(name)-\(appearance).png")) }
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = "\(name)-\(appearance)"
            a.lifetime = .keepAlways
            add(a)
        }
        func text(containing s: String) -> XCUIElement {
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
        }

        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoMarkdown", "-appearance", appearance]
        app.launch()

        let status = text(containing: "Model: claude-opus-5-5 (custom)")
        XCTAssertTrue(status.waitForExistence(timeout: 15), "the /status answer is not drawn")
        XCTAssertFalse(text(containing: "**Model:**").exists, "raw ** in the /status answer")
        XCTAssertFalse(text(containing: "`claude-opus-5-5`").exists, "raw backticks in the /status answer")

        let sample = text(containing: "Bold, italic, gone and inline code.")
        XCTAssertTrue(sample.exists, "the sample is not drawn")
        XCTAssertTrue(sample.label.contains("•  Chat bubbles read markdown"), "no bullet: \(sample.label)")
        XCTAssertTrue(sample.label.contains("swift test --filter BubbleMarkdown"), "no code block")
        XCTAssertFalse(sample.label.contains("```"), "raw fence in the sample")
        XCTAssertFalse(app.buttons["Read as pages"].exists, "a short markdown answer folded")

        // The person's own words stay as typed.
        XCTAssertTrue(app.staticTexts["Show me **everything** you can format"].exists, "the user bubble changed")
        sleep(1)
        shot("markdown")

        // Held: the lifted bubble draws the same way (what Copy takes: BubbleMarkdownTests).
        status.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 5), "no hold menu")
        sleep(1)
        shot("markdown-held")
    }
}
