import XCTest

/// Talk about this (YUI-69, spec yuigui spec/TALK-ABOUT.md). Demo account with the
/// stand-in Controls host, no network: the button on each item screen, the chip it
/// pins above the composer (tap opens the item read only, x takes it off, a second
/// item replaces the first), and the sent bubble's "About SOUL.md" tag, with the
/// proposal the host would draw (the demo reply). Light and dark; shots go to `YUI_SHOTS`.
final class TalkAboutTests: XCTestCase {
    func testLight() throws { try run("light") }
    func testDark() throws { try run("dark") }

    /// What the plugin draws for a SOUL.md proposal (hermes-plugin/yui/talk.py), as the demo agent's reply.
    static let proposal = [
        "say Calm and brief while you work, same warmth after. +inline",
        "sketch \"SOUL.md\" frame=window before=Now +inline",
        "row \"Scout\" +dim",
        "row \"Warm, upbeat, a little playful.\" +x note=\"removed\"",
        "row \"Short sentences.\" +dim",
        "after Proposed",
        "row \"Scout\" +dim",
        "row \"Calm and brief while you work. Warm after.\" +hi note=\"new\"",
        "row \"Short sentences.\" +dim",
        "choose@prop-p-1 \"Apply this change?\" Apply|\"Keep it as is\" +inline",
    ].joined(separator: "\\n")

    private var tag = ""
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

    private func run(_ appearance: String) throws {
        tag = "talk-\(appearance)"
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiDemoControls", "-yuiAgent", "coach",
                               "-yuiDrawer", "-appearance", appearance, "-yuiDemoReply", Self.proposal]
        app.launch()

        func text(_ s: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
        }
        func openControls(_ area: String) {
            if !app.buttons["drawer-close"].exists {
                app.buttons["Agent menu"].tap()
                XCTAssertTrue(app.buttons["drawer-close"].waitForExistence(timeout: 5), "the drawer did not open")
                sleep(1)
            }
            let tab = app.buttons["drawer-tab-controls"]
            XCTAssertTrue(tab.waitForExistence(timeout: 15), "no Controls tab for an owned agent")
            tab.tap()
            let row = app.buttons["controls-\(area)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.tap()
        }
        let chip = app.buttons["about-chip"]
        let talk = app.buttons["controls-talk-about"]

        // Personality: the button under the item.
        openControls("soul")
        XCTAssertTrue(app.descendants(matching: .any)["controls-rendered"].waitForExistence(timeout: 8), "SOUL.md did not load")
        XCTAssertTrue(talk.waitForExistence(timeout: 4), "no Talk about this on SOUL.md")
        sleep(1)
        shot("01-soul-button")
        talk.tap()

        // Back on screen 1, the drawer shut, the item on the composer, the keyboard up.
        XCTAssertTrue(chip.waitForExistence(timeout: 6), "no chip above the composer")
        XCTAssertFalse(app.staticTexts["controls-sheet"].exists, "the Controls sheet stayed up")
        XCTAssertEqual(chip.label, "About SOUL.md, Personality")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4), "the keyboard did not come up")
        sleep(1)
        shot("02-chip")

        // A tap opens the item read only.
        chip.tap()
        let preview = app.descendants(matching: .any)["about-preview-text"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "the chip did not open the item")
        XCTAssertTrue(text("trail-running coach").exists, "the preview is not the item")
        XCTAssertFalse(app.buttons["controls-edit"].exists, "the preview can be edited")
        sleep(1)
        shot("03-chip-open")
        app.buttons["about-preview-close"].tap()
        XCTAssertTrue(chip.waitForExistence(timeout: 4))

        // A second item replaces the first.
        openControls("memory")
        XCTAssertTrue(text("Knee felt tight").waitForExistence(timeout: 8))
        text("Knee felt tight").tap()
        XCTAssertTrue(talk.waitForExistence(timeout: 8), "no Talk about this on a memory")
        talk.tap()
        XCTAssertTrue(chip.waitForExistence(timeout: 6))
        let memory = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "About Knee felt tight"), object: chip)
        XCTAssertEqual(XCTWaiter.wait(for: [memory], timeout: 5), .completed, "the memory did not replace SOUL.md: \(chip.label)")
        sleep(1)
        shot("04-chip-replaced")

        // x takes it off.
        app.buttons["about-chip-remove"].tap()
        sleep(1)
        XCTAssertFalse(chip.exists, "x did not take the chip off")

        // The model card is read only, and still has the button.
        openControls("model")
        XCTAssertTrue(talk.waitForExistence(timeout: 8), "no Talk about this on the model card")
        sleep(1)
        shot("05-model-button")
        talk.tap()
        XCTAssertTrue(chip.waitForExistence(timeout: 6))
        XCTAssertEqual(chip.label, "About Model and tools, Model and tools")

        // Back to SOUL.md, and send: the bubble says what it's about; the proposal comes back.
        openControls("soul")
        XCTAssertTrue(talk.waitForExistence(timeout: 8))
        talk.tap()
        XCTAssertTrue(chip.waitForExistence(timeout: 6))
        let field = app.textFields["composer"].exists ? app.textFields["composer"] : app.textViews["composer"]
        field.typeText("Less playful when I'm working. Keep the warmth.")
        shot("06-typed")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts["Less playful when I'm working. Keep the warmth."].waitForExistence(timeout: 5),
                      "the message did not land")
        XCTAssertTrue(text("About SOUL.md").waitForExistence(timeout: 3), "the bubble has no About tag")
        XCTAssertFalse(text("[yui] attach").exists, "the attach line shows in the chat")
        XCTAssertTrue(chip.exists, "the chip left before the talk was over")
        XCTAssertTrue(app.buttons["Apply"].waitForExistence(timeout: 10), "no proposal came back")
        XCTAssertTrue(app.buttons["Keep it as is"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))  // the keyboard down: a drag, not a tap
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        sleep(2)
        shot("07-proposal")
    }
}
