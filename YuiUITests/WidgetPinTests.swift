import XCTest

/// Saved screens as widgets (YUI-40). The app keeps a copy of every saved screen in the app group;
/// the shelf's hold menu has "Pin as widget"; the widget's own views draw the copy. The simulator's
/// home screen cannot be scripted, so the second launch draws the same views from the same copy.
final class WidgetPinTests: XCTestCase {
    private var app: XCUIApplication!

    private let lines = [
        #"stat 178.9lb Weight delta=-2.3 spark=181.2|180.6|179.8|178.9 good=down sub="this week" +inline"#, "save weight", "clear",
        #"list Today "Walk 30 min" "Stretch" "Read" +check +inline"#, "save today", "clear",
        #"chart line Weight x=Mon|Tue|Wed|Thu y=181|180.2|179.4|178.9 +inline"#, "save trend", "clear",
        #"card "Leg day" "Squat, RDL, lunges." sub=Thursday +inline"#, "save workout",
    ]

    private func launch(_ appearance: String, _ extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "wizard", "-appearance", appearance,
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

    private func pinAndDraw(_ appearance: String) {
        launch(appearance)
        let chip = app.buttons["Open weight"]
        XCTAssertTrue(chip.waitForExistence(timeout: 20), "weight is not on the shelf")
        chip.press(forDuration: 1.0)
        let pin = app.buttons["Pin as widget"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5), "no Pin as widget in the hold menu")
        pin.tap()
        XCTAssertTrue(app.descendants(matching: .any)["pin-widget-sheet"].firstMatch.waitForExistence(timeout: 5), "no pin steps")
        shot("pin-sheet-\(appearance)")
        app.terminate()

        // The copy the widget reads is in the app group: draw it with the widget's views.
        launch(appearance, ["-yuiWidgetsGallery"])
        XCTAssertTrue(app.descendants(matching: .any)["widget-gallery"].firstMatch.waitForExistence(timeout: 20), "no widget gallery")
        let count = app.staticTexts["gallery-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.label, "widgets: 4", "the app group copy does not hold the four saved screens")
        shot("widgets-\(appearance)")
    }

    func testPinAndDrawLight() { pinAndDraw("light") }
    func testPinAndDrawDark() { pinAndDraw("dark") }
}
