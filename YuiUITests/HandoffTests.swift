import XCTest

/// Hand-offs (YUI-144): Yui passes the person to Basil with a note. The hand-off is one
/// card, `url=yui://agent/basil`; when it lands live the app jumps to Basil's thread,
/// where Basil answers with the note. Demo account, no network: `-yuiDemoReply` is what
/// Yui's runtime writes, `-yuiDemoHandoffReply` is Basil's answer to the note.
/// Screenshots go to `YUI_SHOTS` when set.
final class HandoffTests: XCTestCase {
    /// Yui's answer as the runtime writes it: the words, then the card it adds (runtime/src/handoff.ts).
    static let yui = """
    Basil is your food person. I passed it on.
    ```yui
    card "Basil" body="She just finished leg day and wants dinner ideas" url=yui://agent/basil cta="Open Basil"
    ```
    """
    static let basil = """
    say Leg day dinner, coming up. Protein and carbs to refill.
    list Tonight "Salmon, rice and greens" "Chicken burrito bowl" "Steak, sweet potato, broccoli" +check
    choose "Want the recipe for one?" Salmon|Burrito|Steak
    """

    private var appearance: String { ProcessInfo.processInfo.environment["YUI_APPEARANCE"] ?? "light" }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = "handoff-\(name)-\(appearance)"
        a.lifetime = .keepAlways
        add(a)
        guard let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] else { return }
        try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "handoff-\(name)-\(appearance).png"))
    }

    func testYuiHandsOffToBasilAndTheAppJumps() {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemo", "-yuiDemoFirstLaunch", "-yuiAgent", "yui", "-yuiStageFirst", "NO", "-yuiDemoHandoffAfter", "6",
                               "-appearance", appearance,
                               "-yuiDemoReply", Self.yui.replacingOccurrences(of: "\n", with: "\\n"),
                               "-yuiDemoHandoffReply", Self.basil.replacingOccurrences(of: "\n", with: "\\n")]
        app.launch()
        let field = app.descendants(matching: .any)["composer"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no composer")
        field.tap()
        field.typeText("What should I eat after leg day?")
        app.buttons["Send"].tap()

        // The card lands in Yui's thread: who and why, with a button that does the same.
        let open = app.buttons["Open Basil"]
        XCTAssertTrue(open.waitForExistence(timeout: 20), "no hand-off card")
        XCTAssertTrue(app.staticTexts["She just finished leg day and wants dinner ideas"].exists, "no note on the card")
        // Keyboard down (drag the thread), so the card and its button show whole.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)))
        sleep(1)
        let bottom = app.buttons["jump-to-bottom"]
        if bottom.exists { bottom.tap(); sleep(1) }
        shot("1-yui-hands-off")

        // A beat later the app is in Basil's thread, and Basil answers the note.
        let answer = app.staticTexts["Salmon, rice and greens"]
        XCTAssertTrue(answer.waitForExistence(timeout: 15), "the app did not jump to Basil, or Basil did not answer")
        XCTAssertFalse(app.buttons["Open Basil"].exists, "still in Yui's thread")
        sleep(1)
        shot("2-basil-answers")
    }
}
