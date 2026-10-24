import XCTest

/// An explain answer that is one deck plays as the deck's own stage on the stage (Oct 17): the drawing most
/// of the screen, the page turning on the bar's arrow, the quiz inside it, the loose question last.
/// Demo account, no network. Screenshots go to `YUI_SHOTS` when set.
final class StageDeckDemoTests: XCTestCase {
    static let deck = """
Strings, not dots.
```yui
deck "String theory, simple"
page "Particles are not dots" body="Physics treats particles as points with no size. String theory says the smallest things are tiny vibrating strings, not dots."
shapes caption="Points become loops. Same stuff, different shape."
shape dot "Point particle"
shape arrow
shape circle "String loop" +pulse
page "One string, many notes" body="A string vibrating one way is an electron. Another vibration is a photon. Another, a graviton, the particle that carries gravity."
shapes caption="One string, many vibrations"
shape circle O
shape arrow
shape box Electron tone=mint
shape arrow
shape box Photon tone=butter
shape arrow
shape box Graviton
page "Ten dimensions" body="The math only works with extra dimensions, curled up so small we never see them."
shapes caption="Six more, rolled up tight"
shape circle "Our 4" +fill
shape arrow
shape contour "6 hidden" rings=5
page "Not proven yet" body="No one has seen a string. The math is beautiful but there is no proof."
shapes caption="Beautiful math, no evidence"
shape box "The math" tone=mint +fill
shape arrow +dash
shape box "A string" +dash
choose "Which is a string, really?" "A tiny dot"|"A tiny vibrating loop"|"A wave" answer="A tiny vibrating loop"
end
choose "Keep going?" "The grown-up version"|"Why ten dimensions?"|"Done"
```

"""

    func testADeckPlaysWholeOnTheStage() throws {
        let shots = ProcessInfo.processInfo.environment["YUI_SHOTS"].map { URL(fileURLWithPath: $0) }
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            if let shots { try? png.write(to: shots.appending(path: "\(name).png")) }
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = name
            a.lifetime = .keepAlways
            add(a)
        }
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "stage-deck-\(UUID().uuidString).txt")
        try Self.deck.write(to: file, atomically: true, encoding: .utf8)
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiStageFirst", "YES",
                               "-yuiDemoQuickAction", "yui/ask/take me through what string theory is",
                               "-yuiDemoReplyFile", file.path]
        app.launch()
        // The deck is filmed on the phone: the kit draws it in the stage's page, no slides.
        let film = app.descendants(matching: .any)["stage-film"]
        XCTAssertTrue(film.waitForExistence(timeout: 20), "the deck plays as a film")
        XCTAssertFalse(app.staticTexts["Particles are not dots"].exists, "no slide of words is drawn")
        sleep(3)
        shot("film-03s")
        sleep(4)
        shot("film-07s")
        sleep(6)
        shot("film-13s")
        // The film is one page; the arrow goes on to the questions, every one of the deck's on one screen.
        let next = app.descendants(matching: .any)["stage-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.tap()
        XCTAssertTrue(app.descendants(matching: .any)["stage-questions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Which is a string, really?"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Keep going?"].exists)
        sleep(1)
        shot("film-questions")
        // Back one: the film again.
        app.descendants(matching: .any)["stage-back"].tap()
        XCTAssertTrue(film.waitForExistence(timeout: 5))
    }
}
