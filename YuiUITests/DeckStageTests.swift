import XCTest

/// A deck is a stage, not a card (TestFlight feedback ANhbech_, AMt71OZy, AHdP_lC4, Oct 5: "a card in a
/// card with a tiny little stupid drawing", "a shitty PowerPoint deck"). The string theory deck, five
/// pages and a quiz, on the full screen: edge to edge, no card, no dots, no arrows to see, and a slow
/// swipe that scrubs one page's drawing into the next. Demo account, no network. `YUI_SHOTS=<dir>` saves
/// every page; `YUI_RECORD_PAUSE=<s>` holds each page longer for a screen recording.
final class DeckStageTests: XCTestCase {
    static let deck = """
    say "String theory, simple. Swipe through."
    >full
    deck "String theory, simple"
    page "Everything is made of tiny bits" body="Zoom into anything: atoms, then smaller bits. We thought the smallest bits were dots."
    shapes h=8
    shape@atom circle at=5,4 size=6.4 tone=lavender +dash
    shape@bit dot "Smallest bit" at=5,4 +pulse
    shape@b2 dot at=3,2.6 tone=mute
    shape@b3 dot at=7.1,3.1 tone=mute
    shape@b4 dot at=4,6 tone=mute
    page "Zoom in. It is a loop." body="String theory says each bit is a tiny loop of string, like a rubber band."
    shapes h=8
    shape@bit circle "String" at=5,4 size=4.6 tone=mint +pulse +hand
    shape@zoom text "a billion billion times closer" at=5,7.4 tone=mute
    page "One string, many wiggles" body="The loop can wiggle in different ways. Each wiggle is a different thing."
    shapes h=8
    shape@bit path pts=5.00,1.25|5.77,2.15|6.94,2.06|6.85,3.23|7.75,4.00|6.85,4.77|6.94,5.94|5.77,5.85|5.00,6.75|4.23,5.85|3.06,5.94|3.15,4.77|2.25,4.00|3.15,3.23|3.06,2.06|4.23,2.15 +close +fill tone=mint +pulse
    shape@light pill "Fast: light" at=1.6,1.2 tone=butter
    shape@matter pill "Slow: matter" at=8.4,1.6 tone=lavender
    shape@grav pill "Special: gravity" at=5,7.6 tone=accent
    page "Like notes on a guitar" body="One string plays many notes. Each note is a particle: light, matter, gravity."
    shapes h=8
    shape@pegl dot at=0.8,3.4 tone=ink
    shape@bit path "One string" pts=0.8,3.4|3,2.4|5,3.4|7,4.4|9.2,3.4 tone=mint +pulse
    shape@pegr dot at=9.2,3.4 tone=ink
    shape@light pill "Light" at=2,6.4 tone=butter
    shape@matter pill "Matter" at=5,6.4 tone=lavender
    shape@grav pill "Gravity" at=8,6.4 tone=accent
    page "Nobody has seen one yet" body="Strings would be far too small for any machine we have. The math is beautiful. The proof is not here yet."
    shapes h=8
    shape@bit circle "?" at=2.6,4 size=1.6 tone=mint +dash +pulse
    shape@lab box "Biggest collider" at=7.4,4 size=3.4 tone=lavender +fill
    shape arc "too small to see" from=lab to=bit bend=-0.3 tone=mute +dash
    choose "In string theory, what is everything made of?" "Tiny dots"|"Tiny wiggling strings"|"Atoms" answer="Tiny wiggling strings"
    """

    static let titles = ["Everything is made of tiny bits", "Zoom in. It is a loop.", "One string, many wiggles",
                         "Like notes on a guitar", "Nobody has seen one yet"]

    func testDark() { run("dark") }
    func testLight() { run("light") }

    private func run(_ appearance: String) {
        let app = XCUIApplication()
        let shots = ProcessInfo.processInfo.environment["YUI_SHOTS"].map { URL(fileURLWithPath: $0) }
        let pause = UInt32(ProcessInfo.processInfo.environment["YUI_RECORD_PAUSE"] ?? "") ?? 0
        func shot(_ name: String) {
            let s = XCUIScreen.main.screenshot()
            try? s.pngRepresentation.write(to: (shots ?? URL(fileURLWithPath: NSTemporaryDirectory())).appending(path: "deck-\(name)-\(appearance).png"))
            let a = XCTAttachment(screenshot: s)
            a.name = "deck-\(name)-\(appearance)"
            a.lifetime = .keepAlways
            add(a)
        }
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemo", "-appearance", appearance, "-yuiDemoReply",
                               Self.deck.replacingOccurrences(of: "\n", with: "\\n")]
        app.launch()
        let field = app.descendants(matching: .any)["composer"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no composer")
        field.tap()
        field.typeText("ELI5 string theory")
        app.buttons["Send"].tap()

        let stage = app.descendants(matching: .any)["deck-stage"].firstMatch
        XCTAssertTrue(stage.waitForExistence(timeout: 20), "the deck never opened as a stage")
        XCTAssertTrue(app.staticTexts[Self.titles[0]].waitForExistence(timeout: 10), "page one is not up")

        // No card: the stage runs edge to edge, and nothing on it is a pager.
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(stage.frame.width, window.width, accuracy: 2, "the deck sits in a card, not on the stage")
        XCTAssertFalse(app.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Page 1 of")).firstMatch.exists,
                       "the deck still draws page dots")
        XCTAssertFalse(app.staticTexts["5 pages"].exists, "the deck still has a card header")
        sleep(2 + pause)
        shot("01")

        let next = app.buttons.matching(NSPredicate(format: "label == %@", "Next page")).firstMatch
        for i in 1..<Self.titles.count {
            // A slow drag from right to left: the drawing scrubs with the finger.
            let from = stage.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.35))
            let to = stage.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.35))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: 260, thenHoldForDuration: 0.1)
            if !app.staticTexts[Self.titles[i]].waitForExistence(timeout: 3) { next.tap() }
            XCTAssertTrue(app.staticTexts[Self.titles[i]].waitForExistence(timeout: 5), "page \(i + 1) is not \(Self.titles[i])")
            sleep(2 + pause)
            shot(String(format: "%02d", i + 1))
        }
        // The quiz is the last page; a tap on the drawing's right half turns to it.
        next.tap()
        XCTAssertTrue(app.buttons["Tiny wiggling strings"].waitForExistence(timeout: 5), "the quiz is not the last page")
        sleep(1 + pause)
        shot("06-quiz")
        app.buttons["Tiny wiggling strings"].tap()
        sleep(1 + pause)
        shot("07-answered")
    }
}
