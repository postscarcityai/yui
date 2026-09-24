import XCTest

/// Every Done does something (TestFlight feedback, 2026-09-24: "The done button
/// doesn't work"). A `+pick` gallery kept Done disabled until a tile's small
/// circle was ticked, and nothing said so, so a tap on Done did nothing. Done
/// now always answers: the picks, or none.
final class DoneButtonTests: XCTestCase {
    private var app: XCUIApplication!
    private var log = ""
    private var tag = ""

    private func launch(_ tag: String, _ lines: [String]) {
        self.tag = tag
        log = FileManager.default.temporaryDirectory.appending(path: "yui-done-\(tag).jsonl").path
        try? FileManager.default.removeItem(atPath: log)
        app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "wizard", "-appearance", "dark",
                               "-yuiThemeDemo", lines.joined(separator: "\\n"), "-yuiEventLog", log]
        app.launch()
    }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(tag)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "\(tag)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func events() -> [[String: Any]] {
        let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    private func waitEvent(_ preset: String, _ key: String, timeout: TimeInterval = 6) -> [String: Any]? {
        let end = Date.now.addingTimeInterval(timeout)
        while Date.now < end {
            if let e = events().last(where: { $0["preset"] as? String == preset && $0[key] != nil }) { return e }
            usleep(250_000)
        }
        return nil
    }

    private func ready(_ e: XCUIElement) -> Bool {
        e.exists && !e.frame.isEmpty && e.frame.minY > 100 && e.frame.maxY < app.frame.maxY - 90 && e.isHittable
    }

    /// Tap near the left end, not dead center: an overlapping tile or a glyph-only
    /// hit area would take this tap and not the button.
    private func tapOffCenter(_ e: XCUIElement) {
        e.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.3)).tap()
    }

    /// The screen Chris was on: a `+pick` gallery, nothing ticked, Done tapped.
    func testGalleryDoneWithNothingPicked() throws {
        launch("gallery", [#"gallery "Fresh renders" /demo/g1.jpg|"Hello" /demo/g2.jpg|Cafe +pick"#])
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 20), "the gallery never arrived")
        var n = 0
        while !ready(done), n < 6 { app.swipeUp(velocity: .slow); n += 1 }
        sleep(2)
        shot("1-before")
        XCTAssertTrue(done.isEnabled, "Done is disabled with nothing picked, so a tap does nothing")
        tapOffCenter(done)
        let e = waitEvent("gallery", "picked")
        XCTAssertNotNil(e, "Done sent nothing")
        XCTAssertEqual(e?["picked"] as? [Int], [])
        XCTAssertTrue(app.buttons["Sent"].waitForExistence(timeout: 3), "Done did not settle on Sent")
        shot("2-after")
    }

    /// With picks, Done still sends them.
    func testGalleryDoneWithPicks() throws {
        launch("gallery-picks", [#"gallery "Fresh renders" /demo/g1.jpg|"Hello" /demo/g2.jpg|Cafe +pick"#])
        let pick = app.buttons.matching(NSPredicate(format: "label == %@", "Pick")).firstMatch
        XCTAssertTrue(pick.waitForExistence(timeout: 20), "the gallery never arrived")
        sleep(2)
        pick.tap()
        let done = app.buttons["Done"]
        var n = 0
        while !ready(done), n < 6 { app.swipeUp(velocity: .slow); n += 1 }
        tapOffCenter(done)
        XCTAssertEqual(waitEvent("gallery", "picked")?["picked"] as? [Int], [0])
    }

    /// `pick` had the same dead Done.
    func testPickDoneWithNothingPicked() throws {
        launch("pick", [#"pick "What do you have?" Dumbbells|Barbell|Bands"#])
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 20), "the pick never arrived")
        sleep(2)
        XCTAssertTrue(done.isEnabled, "pick's Done is disabled with nothing picked")
        tapOffCenter(done)
        XCTAssertEqual(waitEvent("pick", "picked")?["picked"] as? [String], [])
        shot("pick-after")
    }

    /// The Back/Done card above it in the screenshot: a one-step stepper.
    func testStepperDone() throws {
        launch("step", [#"step "Divide by g" $ t^2 = 2d/g"#])
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 20), "the stepper never arrived")
        sleep(2)
        tapOffCenter(done)
        XCTAssertNotNil(waitEvent("step", "done"), "the stepper's Done sent nothing")
        XCTAssertTrue(gone(done), "Done is still up after the last step")
    }

    private func gone(_ e: XCUIElement, _ timeout: TimeInterval = 4) -> Bool {
        let x = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: e)
        return XCTWaiter.wait(for: [x], timeout: timeout) == .completed
    }
}
