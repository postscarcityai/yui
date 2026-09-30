import XCTest

/// Buttons on the widget (YUI-40 step 3): a checklist row toggles at once and queues the event for the agent
/// (`via=widget`), a timer's Start runs the Live Activity and the widget then reads Pause, a cta sends its
/// event. The simulator's home screen cannot be scripted, so the widget's own views are drawn in the app's
/// gallery from the same app group copy; the buttons are the same App Intents the widget runs.
final class WidgetButtonTests: XCTestCase {
    private var app: XCUIApplication!

    private let lines = [
        #"list@today Today "Walk 30 min" "Stretch" "Read" +check +inline"#, "save today", "clear",
        #"timer@tabata 20/10x4 Tabata +inline"#, "save tabata", "clear",
        #"stat@weight 178.9lb Weight delta=-2.3 cta="Log today" +inline"#, "save weight",
    ]

    private func launch(_ appearance: String, _ extra: [String] = []) {
        app = XCUIApplication()
        // The first launch starts the app group empty; the gallery launch keeps what the first one saved.
        app.launchArguments = (extra.contains("-yuiWidgetsGallery") ? [] : ["-yuiWidgetsReset", "-yuiTicksReset"]) + ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "wizard", "-appearance", appearance,
                               "-yuiThemeDemo", lines.joined(separator: "\\n")] + extra
        app.launch()
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

    private func gallery(_ appearance: String) {
        launch(appearance)
        for name in ["today", "tabata", "weight"] {
            let ok = app.buttons["Open \(name)"].waitForExistence(timeout: 30)
            if !ok { shot("widget-buttons-first-launch-\(name)") }
            XCTAssertTrue(ok, "\(name) is not on the shelf")
        }
        app.terminate()
        launch(appearance, ["-yuiWidgetsGallery"])
        XCTAssertTrue(app.descendants(matching: .any)["widget-gallery"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertEqual(app.staticTexts["gallery-count"].label, "widgets: 3", "saved: \(app.staticTexts["gallery-names"].label)")
    }

    private func eventually(_ seconds: TimeInterval = 8, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; Thread.sleep(forTimeInterval: 0.25) }
        return cond()
    }

    private func scrollTo(_ e: XCUIElement) {
        let g = app.descendants(matching: .any)["widget-gallery"].firstMatch
        var n = 0
        while !e.isHittable, n < 8 { g.swipeUp(velocity: .slow); n += 1 }
    }

    private func buttonAnywhere(_ label: String) -> XCUIElement {
        app.descendants(matching: .any)["widget-gallery"].buttons.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
    }

    private func run(_ appearance: String) {
        gallery(appearance)
        XCTAssertEqual(app.staticTexts["gallery-queue"].label, "queue: 0")
        shot("widget-buttons-\(appearance)-1-before")

        // A checklist row is a toggle: it flips on the widget at once and the event waits for the agent.
        let walk = buttonAnywhere("Walk 30 min")
        XCTAssertTrue(walk.waitForExistence(timeout: 5), "no toggle for the first item")
        let queued = app.staticTexts["gallery-queue"]
        for _ in 0..<3 where queued.label != "queue: 1" {
            scrollTo(walk)
            walk.tap()
            _ = eventually(3) { queued.label == "queue: 1" }
        }
        XCTAssertTrue(eventually { queued.label == "queue: 1" }, "the tick never reached the queue: \(queued.label)")
        XCTAssertEqual(app.staticTexts["gallery-event"].label, "[yui] today list checked item=\"Walk 30 min\" saved=today via=widget")
        shot("widget-buttons-\(appearance)-2-ticked")

        // Start on the timer: the clock runs, the button reads Pause.
        let start = app.descendants(matching: .any)["widget-gallery"].buttons["Start"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 5), "no Start on the timer")
        scrollTo(start)
        start.tap()
        let pause = app.descendants(matching: .any)["widget-gallery"].buttons["Pause"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 10), "Start did not turn into Pause")
        shot("widget-buttons-\(appearance)-3-timer-running")

        // A cta on a stat sends its event.
        let cta = app.descendants(matching: .any)["widget-gallery"].buttons["Log today"].firstMatch
        XCTAssertTrue(cta.waitForExistence(timeout: 5), "no cta button")
        scrollTo(cta)
        cta.tap()
        XCTAssertTrue(eventually { app.staticTexts["gallery-event"].label.contains("cta=\"Log today\"") }, "the cta never reached the queue")
        XCTAssertTrue(app.staticTexts["gallery-event"].label.contains("via=widget"))
        shot("widget-buttons-\(appearance)-4-cta")

        // Pause stops the clock on the widget.
        scrollTo(pause)
        pause.tap()
        XCTAssertTrue(app.descendants(matching: .any)["widget-gallery"].buttons["Resume"].firstMatch.waitForExistence(timeout: 10), "Pause did not turn into Resume")
    }

    func testButtonsLight() { run("light") }
    func testButtonsDark() { run("dark") }
}
