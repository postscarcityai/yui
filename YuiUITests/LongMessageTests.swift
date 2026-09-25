import XCTest

/// Long plain answers (YUI-79, TestFlight build 82: "I don't want these text
/// bombs"). The INT-18 report, about 300 words, folds in the thread to its first
/// sentences and "Read as pages"; the pages open full screen, swipe, show where
/// you are, and close back to the chat. A short answer stays a plain bubble.
/// Demo account, no network. Screenshots go to `TEST_RUNNER_YUI_SHOTS` when set.
final class LongMessageTests: XCTestCase {
    func testLongAnswerFoldsAndReadsAsPages() throws {
        try run(appearance: "light")
    }

    func testDark() throws {
        try run(appearance: "dark")
    }

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
        func text(_ prefix: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        }
        func anyText(containing s: String) -> XCUIElement {
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
        }

        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoLong", "-appearance", appearance]
        app.launch()

        // Folded: the first sentences, well under a screen, and the button.
        let read = app.buttons["Read as pages"]
        XCTAssertTrue(read.waitForExistence(timeout: 15), "no Read as pages on the long answer")
        XCTAssertEqual(app.buttons.matching(identifier: "read-as-pages").count, 1, "only the long answer folds")
        XCTAssertTrue((read.value as? String)?.hasSuffix("pages") == true, "no page count on the button")
        let folded = text("A2A bridge: add any A2A agent")
        XCTAssertTrue(folded.exists)
        XCTAssertTrue(folded.label.hasSuffix("…"), "the excerpt does not end in an ellipsis: \(folded.label)")
        XCTAssertLessThan(folded.frame.height, app.frame.height * 0.3, "the bubble is still a wall")
        XCTAssertFalse(anyText(containing: "No app binary change").exists, "the report's end is in the thread")

        // The short answer is the whole bubble, not folded.
        let short = "It went well. Every test is green and the phone run passed in light and dark. Want the whole report?"
        XCTAssertTrue(app.staticTexts[short].exists, "the short answer is not shown whole")
        sleep(1)
        shot("after")

        // Open: full screen, the first page.
        read.tap()
        let close = app.buttons["Close full screen"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the pages did not open")
        sleep(1)
        XCTAssertTrue(close.isHittable)
        let dots = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Page 1 of'")).firstMatch
        XCTAssertTrue(dots.exists, "no page indicator")
        let first = anyText(containing: "puts more agents on the same machine")
        XCTAssertTrue(first.exists && first.isHittable, "the first page is not showing")
        shot("pages")

        // Swipe: the next page, different words.
        app.swipeLeft()
        let second = anyText(containing: "Runtime-neutral TypeScript client")
        XCTAssertTrue(second.waitForExistence(timeout: 4))
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: second)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 4), .completed, "the swipe did not turn the page")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Page 2 of'")).firstMatch.exists)
        app.swipeLeft()
        sleep(1)
        shot("pages-middle")

        // The X: back in the chat, still folded.
        close.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 4), .completed, "the X did not close the pages")
        XCTAssertTrue(read.isHittable, "not back in the chat")
        XCTAssertTrue(app.textViews["composer"].exists || app.textFields["composer"].exists, "no composer after closing")
    }
}
