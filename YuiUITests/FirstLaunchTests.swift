import XCTest

/// A new person's first launch (YUI-145, NATIVE-1): the app opens on Yui talking, with
/// the crew already in the list, and no pairing step anywhere on the way. Add agent
/// offers the crew by name, one tap each, beside pairing your own, and a tap only adds
/// (feedback APsS404f7C). Controls shows a native agent's model and profile version.
/// Demo account with the list yui-agents provisions (`-yuiDemoFirstLaunch`), no network.
/// `TEST_RUNNER_YUI_SHOTS=<dir>` saves screenshots.
final class FirstLaunchTests: XCTestCase {
    func testLight() throws { try run("light") }
    func testDark() throws { try run("dark") }

    /// Yui's answer to "Get fit": no apostrophes, a launch argument can't carry them.
    static let getFit = [
        "say \"Arnold is your trainer. He is in your list already, with a plan for your week.\"",
        "card \"Arnold\" body=\"Trainer. Asks about injuries first, then builds a week you will actually do.\"",
    ].joined(separator: "\\n")

    /// The crew is the person's choice (Chris, 2026-09-27: "either have all these agents or can
    /// put any number of them to be in my list"). With every one removed, the first screen offers
    /// the crew (never the pairing pitch): one tap adds one, "Add all 6" adds everyone. Add agent
    /// opened and cancelled leaves the app standing (build 229 crash AGjOqLXNI70o).
    func testPickTheCrew() throws {
        tag = "light"
        let app = XCUIApplication()
        func text(_ s: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
        }
        launch(app, ["-yuiDemoWithout", "all", "-yuiNoAgents"])
        let all = app.descendants(matching: .any)["crew-all"]
        XCTAssertTrue(all.waitForExistence(timeout: 15), "the empty list does not offer the crew")
        XCTAssertFalse(app.buttons["Add your first agent"].exists, "the pairing first run shows")
        XCTAssertFalse(app.recordTitle().exists, "the agent title shows with no agents")
        XCTAssertTrue(app.buttons["first-run-pair"].exists, "pairing your own is gone")
        sleep(1)
        shot("07-pick")
        app.descendants(matching: .any)["crew-arnold"].tap()
        XCTAssertTrue(text("Arnold").waitForExistence(timeout: 15), "Arnold's thread did not open")
        sleep(1)
        shot("08-just-arnold")

        launch(app, ["-yuiDemoWithout", "all", "-yuiNoAgents"])
        XCTAssertTrue(all.waitForExistence(timeout: 15))
        all.tap()
        XCTAssertTrue(text("Your crew is here").waitForExistence(timeout: 15), "Add all did not land on Yui talking")
        sleep(1)
        shot("09-all")

        // Add agent, then Cancel: the chat is back and the app still runs.
        launch(app, ["-yuiDemoWithout", "arnold", "-yuiAgents", "-yuiAddAgent"])
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 15), "Add agent did not open")
        cancel.tap()
        sleep(2)
        XCTAssertEqual(app.state, .runningForeground, "the app died after Cancel")
    }

    /// Gouda's hello is an answer on its stage, a beat to play and a pick, never "1 thing is
    /// waiting on you" in the drawer's Review (YUI-165, Chris on build 244: "this is the total
    /// wrong place for this. This is not something for me to review").
    func testTheHelloIsNotAReviewAsk() throws {
        for look in ["light", "dark"] {
            tag = look
            let app = XCUIApplication()
            launch(app, ["-yuiAgent", "gouda"])
            let pick = app.buttons["Make a beat"].firstMatch
            XCTAssertTrue(pick.waitForExistence(timeout: 20), "Gouda's hello is not on screen")
            sleep(2)
            shot("10-gouda-hello")
            launch(app, ["-yuiAgent", "gouda", "-yuiDrawer"])
            let review = app.buttons["drawer-tab-review"]
            XCTAssertTrue(review.waitForExistence(timeout: 15), "no Review tab")
            review.tap()
            XCTAssertTrue(app.staticTexts["All caught up."].waitForExistence(timeout: 5), "the hello sits in Review")
            XCTAssertFalse(app.buttons["review-drawer"].exists, "a review card for the hello")
            sleep(1)
            shot("11-gouda-review")
        }
    }

    private var tag = ""
    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "first-\(name)-\(tag).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "\(tag)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func launch(_ app: XCUIApplication, _ extra: [String]) {
        app.terminate()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoFirstLaunch", "-appearance", tag] + extra
        app.launch()
    }

    private func run(_ appearance: String) throws {
        tag = appearance
        let app = XCUIApplication()
        func text(_ s: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
        }

        // 1. The first launch lands in Yui's thread, Yui already talking. No empty list, no pairing.
        launch(app, ["-yuiDemoReply", Self.getFit, "-yuiDemoReplyTaps"])
        XCTAssertTrue(text("Your crew is here").waitForExistence(timeout: 20), "Yui's first message is not on screen")
        let getFit = app.buttons["Get fit"].firstMatch
        XCTAssertTrue(getFit.waitForExistence(timeout: 5), "Yui's first choice is missing")
        XCTAssertFalse(app.buttons["Add your first agent"].exists, "the pairing first run shows")
        XCTAssertFalse(text("Pairing code").exists, "a pairing step shows")
        sleep(2)
        shot("01-yui")
        getFit.tap()
        XCTAssertTrue(text("Arnold is your trainer").waitForExistence(timeout: 15), "Yui never answered the tap")
        sleep(2)
        shot("02-reply")

        // 2. The crew is already in the list, above the agents a person pairs (Coach, Wizard...).
        launch(app, ["-yuiDemoAgents", "-yuiAgents"])
        func row(_ name: String) -> XCUIElement { app.buttons["Edit \(name)"].firstMatch }
        XCTAssertTrue(row("Yui").waitForExistence(timeout: 15), "the crew is not in the list")
        for name in ["Arnold", "Basil", "Gouda", "Penny"] { XCTAssertTrue(row(name).exists, "\(name) is not in the list") }
        XCTAssertLessThan(row("Yui").frame.minY, row("Arnold").frame.minY, "Yui is not first")
        sleep(1)
        shot("03-list")
        // Further down: the last of the crew, then the paired agents under it.
        app.swipeUp()
        XCTAssertTrue(row("Quill").waitForExistence(timeout: 5), "Quill is not in the list")
        XCTAssertTrue(row("Coach").waitForExistence(timeout: 5), "the paired agents are gone")
        XCTAssertLessThan(row("Quill").frame.minY, row("Coach").frame.minY, "the crew is not above the paired agents")
        sleep(1)
        shot("03b-list-paired")

        // 3. Basil was removed. Add agent offers the crew by name beside pairing your own; one tap
        // puts Basil back and opens his thread, and nothing else in the list changes.
        launch(app, ["-yuiDemoWithout", "basil", "-yuiAgents", "-yuiAddAgent"])
        let basil = app.descendants(matching: .any)["crew-basil"]
        XCTAssertTrue(basil.waitForExistence(timeout: 15), "Add agent does not offer the crew")
        XCTAssertEqual(basil.label, "Add Basil, Nutritionist")
        XCTAssertEqual(app.descendants(matching: .any)["crew-yui"].label, "Yui, in your list")
        XCTAssertEqual(app.descendants(matching: .any)["crew-arnold"].label, "Arnold, in your list")
        XCTAssertTrue(app.buttons["Get a pairing code"].exists, "pairing your own is gone")
        sleep(1)
        shot("04-add")
        basil.tap()
        XCTAssertTrue(text("I'm Basil").waitForExistence(timeout: 15), "Basil's thread did not open on his first message")
        sleep(2)
        shot("05-basil")

        // 4. Controls: the model by its name on the eval list, and the profile's version.
        launch(app, ["-yuiAgent", "basil", "-yuiDrawer"])
        let tab = app.buttons["drawer-tab-agent"]
        XCTAssertTrue(tab.waitForExistence(timeout: 15), "no Agent tab for a native agent")
        tab.tap()
        let model = app.buttons["controls-model"]
        XCTAssertTrue(model.waitForExistence(timeout: 5), "no Model row")
        model.tap()
        XCTAssertTrue(text("Yui's pick").waitForExistence(timeout: 8), "the model is not named")
        XCTAssertTrue(text("Basil, version 1").exists, "the profile version is missing")
        XCTAssertTrue(text("OpenRouter, on Yui").exists)
        sleep(1)
        shot("06-model")
    }
}
