import XCTest

/// Speak to fill a form (feedback AKNFDrNVFCY4IO44-4fjAnc: "I want to use more voice. I should be able
/// to just speak in my answers and it fills it out for me"). The Client website intake flow's
/// "Your business" step: tap the mic, say each field's name and its answer, and the fields fill,
/// each marked with a mic, and Next (held while Business name was empty) opens.
/// `-yuiPTTFake` stands in for the voice (the simulator has no mic). Demo account, no network.
/// `YUI_SHOTS=<dir>` saves screenshots.
final class VoiceFillFormTests: XCTestCase {
    private var appearance = "light"
    private let said = "Business name is Acme Bakery. What you do, we bake sourdough and pastries. Who it is for, people in the neighborhood."

    private func shot(_ name: String) {
        usleep(700_000)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "voicefill-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "voicefill-\(appearance)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    func testLight() throws { try run("light") }
    func testDark() throws { try run("dark") }

    private func run(_ look: String) throws {
        appearance = look
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "yui", "-appearance", look,
                               "-yuiDemoReply", "flow website-intake", "-yuiDemoPickupAfter", "0.5", "-yuiDemoReplyAfter", "1.5",
                               "-yuiPTTFake", said]
        app.launch()

        XCTAssertTrue(app.buttons["stage-type"].waitForExistence(timeout: 15), "no stage")
        app.buttons["stage-type"].tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Plan my site")
        app.buttons["stage-send-text"].tap()

        // The flow opens on its welcome page; Next walks to "Your business".
        let next = app.buttons["flow-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 20), "the flow never opened")
        next.tap()
        let talk = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'form-talk-'")).firstMatch
        XCTAssertTrue(talk.waitForExistence(timeout: 10), "the form has no mic")
        let name = app.textFields["Business name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Business name", "the field starts empty")
        XCTAssertFalse(app.buttons["flow-next"].isEnabled, "Next is open with the required field empty")
        shot("1-before")

        // Talk, then stop: the words fill the fields.
        talk.tap()
        shot("2-listening")
        talk.tap()
        let end = Date().addingTimeInterval(10)
        while (name.value as? String) != "Acme Bakery", Date() < end { usleep(300_000) }
        XCTAssertEqual(name.value as? String, "Acme Bakery", "Business name was not filled")
        func held(_ label: String) -> String {
            let e = app.descendants(matching: .any).matching(NSPredicate(format: "placeholderValue == %@", label)).firstMatch
            return e.exists ? e.value as? String ?? "" : ""
        }
        // The long field is a multi-line box with no placeholder to find it by: look for its words.
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "value CONTAINS %@", "sourdough")).firstMatch.exists,
                      "What you do was not filled")
        XCTAssertEqual(held("Who it is for"), "People in the neighborhood")
        XCTAssertTrue(app.buttons["flow-next"].isEnabled, "Next stayed held after the required field was filled")
        shot("3-filled")
    }
}
