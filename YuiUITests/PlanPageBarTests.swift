import XCTest

/// Plan and form pages keep the stage's bar (+, T, mic) beside Back and Next (TestFlight AF-LecIdpo5GenYXnYNhdm0,
/// Client website intake step 6; t_7d424132). Walks the Client website intake flow on the demo account and
/// shoots every step. `YUI_SHOTS=<dir>` saves the screenshots.
final class PlanPageBarTests: XCTestCase {
    private var look = "dark"

    private func shot(_ name: String) {
        usleep(700_000)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "planbar-\(look)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "planbar-\(look)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    /// The progress bar's bottom to the first field's top, and the last field's bottom to Back.
    private func frames(_ app: XCUIApplication) -> (above: CGFloat, below: CGFloat)? {
        let progress = app.descendants(matching: .any)["flow-progress"].frame
        let fields = app.textFields.allElementsBoundByIndex.filter { $0.isHittable }
        guard let first = fields.first, let last = fields.last, progress.height > 0 else { return nil }
        return (first.frame.minY - progress.maxY, app.buttons["flow-back"].frame.minY - last.frame.maxY)
    }

    /// Said on the bar's mic, the Your business page fills, marked, and Next opens. T still opens the stage's field.
    func testSpeakFillsPage() throws {
        look = "dark"
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "yui", "-appearance", "dark",
                               "-yuiDemoReply", "flow website-intake", "-yuiDemoPickupAfter", "0.5", "-yuiDemoReplyAfter", "1.5",
                               "-yuiPTTFake", "Business name is Acme Bakery. What you do, we bake sourdough. Who it is for, people nearby."]
        app.launch()
        app.buttons["stage-type"].waitForExistence(timeout: 15) ? app.buttons["stage-type"].tap() : XCTFail("no stage")
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Plan my site")
        app.buttons["stage-send-text"].tap()
        let next = app.buttons["flow-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 20))
        next.tap()
        let name = app.textFields["Business name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        for id in ["stage-attach", "stage-type", "stage-mic", "flow-back", "flow-next"] {
            XCTAssertTrue(app.buttons[id].exists, "\(id) is missing beside Back and Next")
        }
        XCTAssertFalse(app.buttons["flow-next"].isEnabled)
        shot("speak-1-before")
        app.buttons["stage-mic"].tap()
        let end = Date().addingTimeInterval(15)
        while (name.value as? String) != "Acme Bakery", Date() < end { usleep(300_000) }
        XCTAssertEqual(name.value as? String, "Acme Bakery", "the page was not filled by the bar's mic")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "value CONTAINS %@", "sourdough")).firstMatch.exists)
        XCTAssertTrue(app.buttons["flow-next"].isEnabled, "Next stayed held")
        if let f = frames(app) { NSLog("PLANBAR speak gaps above=\(f.above) below=\(f.below)") }
        shot("speak-2-filled")
        // Hands-free keeps the mic open; one tap closes it and T is back.
        if !app.buttons["stage-type"].exists { app.buttons["stage-mic"].tap() }
        // T opens the stage's field.
        XCTAssertTrue(app.buttons["stage-type"].waitForExistence(timeout: 8))
        app.buttons["stage-type"].tap()
        XCTAssertTrue(app.textFields["stage-field"].waitForExistence(timeout: 5), "T opened no field")
        shot("speak-3-type")
    }

    func testDark() throws { try walk("dark") }
    func testLight() throws { try walk("light") }

    private func walk(_ appearance: String) throws {
        look = appearance
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "yui", "-appearance", appearance,
                               "-yuiDemoReply", "flow website-intake", "-yuiDemoPickupAfter", "0.5", "-yuiDemoReplyAfter", "1.5",
                               "-yuiPTTFake", "Business name is Acme Bakery. Home and Contact."]
        app.launch()
        XCTAssertTrue(app.buttons["stage-type"].waitForExistence(timeout: 15), "no stage")
        app.buttons["stage-type"].tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Plan my site")
        app.buttons["stage-send-text"].tap()
        XCTAssertTrue(app.buttons["flow-next"].waitForExistence(timeout: 20), "the flow never opened")

        for n in 1...8 {
            usleep(600_000)
            shot("step\(n)")
            let bar = ["stage-mic", "stage-type", "stage-attach"].map { app.descendants(matching: .any)[$0].exists }
            NSLog("PLANBAR step \(n) bar mic/type/attach = \(bar)")
            // Fill what blocks Next, answer a choice by its first option, then go on.
            let name = app.textFields["Business name"]
            if name.exists, (name.value as? String) == "Business name" { name.tap(); name.typeText("Acme") }
            if app.buttons["Landing page"].exists { app.buttons["Landing page"].tap(); continue }
            if app.buttons["Call"].exists { app.buttons["Call"].tap(); continue }
            if app.buttons["Home"].exists { app.buttons["Home"].tap() }
            if let f = frames(app) { NSLog("PLANBAR step \(n) gaps above=\(f.above) below=\(f.below)") }
            if app.buttons["flow-next"].exists, app.buttons["flow-next"].isEnabled { app.buttons["flow-next"].tap() }
            else if app.buttons["flow-review"].exists { break }
        }
    }
}
