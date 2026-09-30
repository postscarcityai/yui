import XCTest

/// YUI-216, pick your crew: a new account (demo, before its pick) lands on the picker, not on six
/// threads. Opens an agent's page, adds it there, taps two more, starts, and the first agent
/// screen is Yui saying hello to only that crew. A second launch takes the "Bring my own agent"
/// branch into pairing. Light and dark. Screenshots to TEST_RUNNER_YUI_SHOTS when set.
final class CrewPickTests: XCTestCase {
    func testPickYourCrewLight() throws { try run("light") }
    func testPickYourCrewDark() throws { try run("dark") }

    private var tag = ""
    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "crew-\(name)-\(tag).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "\(tag)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func launch(_ app: XCUIApplication) {
        app.terminate()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoFirstLaunch", "-yuiDemoPickCrew", "-appearance", tag]
        app.launch()
    }

    private func run(_ appearance: String) throws {
        tag = appearance
        let app = XCUIApplication()
        func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
        func text(_ s: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
        }

        // 1. After sign-in: the picker, Yui alone behind it. No threads, no pairing pitch.
        launch(app)
        XCTAssertTrue(any("crew-pick-title").waitForExistence(timeout: 20), "the picker is not up")
        for base in ["arnold", "basil", "gouda", "penny", "quill"] {
            XCTAssertTrue(any("crew-pick-\(base)").exists, "\(base) is not in the picker")
        }
        XCTAssertTrue(any("crew-own").exists, "Bring my own agent is not in the picker")
        XCTAssertFalse(app.buttons["Add your first agent"].exists, "the pairing first run shows")
        XCTAssertTrue(app.buttons["Start with Yui"].exists, "Start is not there with no one picked")
        sleep(1)
        shot("01-picker")

        // 2. An agent's page: what it does, add it from there.
        any("crew-more-arnold").tap()
        XCTAssertTrue(text("Try asking").waitForExistence(timeout: 10), "Arnold's page did not open")
        sleep(1)
        shot("02-arnold-page")
        any("crew-page-add").tap()
        XCTAssertTrue(app.buttons["Added. Tap to remove"].waitForExistence(timeout: 5), "Add on the page did nothing")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(any("crew-pick-basil").waitForExistence(timeout: 10), "back from the page lost the picker")

        // 3. Two more from the list. Start says how many joined.
        any("crew-pick-basil").tap()
        any("crew-pick-penny").tap()
        XCTAssertTrue(app.buttons["Start with Yui and 3"].waitForExistence(timeout: 5), "Start does not count the pick")
        sleep(1)
        shot("03-picked")

        // 4. Start: the first agent screen is Yui, naming only who joined.
        any("crew-start").tap()
        XCTAssertTrue(text("Your crew is here: Arnold trains, Basil feeds you and Penny keeps your lists").waitForExistence(timeout: 20),
                      "Yui's hello does not name the crew that was picked")
        XCTAssertFalse(text("Gouda makes music").exists, "Yui names an agent that was not picked")
        XCTAssertFalse(any("crew-pick-title").exists, "the picker is still up")
        sleep(2)
        shot("04-yui")

        // 5. Bring my own agent: the branch into pairing, same list.
        launch(app)
        XCTAssertTrue(any("crew-own").waitForExistence(timeout: 20), "the picker is not up")
        any("crew-own").tap()
        XCTAssertTrue(app.buttons["Get a pairing code"].waitForExistence(timeout: 10), "Bring my own agent did not open pairing")
        sleep(1)
        shot("05-pairing")
    }
}
