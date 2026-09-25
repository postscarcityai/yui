import XCTest

/// Tall phone screenshots in a gallery stay inside it (TestFlight feedback,
/// 2026-09-24, build 33: "We're still having an overlap problem with images").
/// Yui sent a gallery of app screenshots (about 1:2.2) and the question card
/// under it was drawn over the photos. Every layout, with and without +pick:
/// no tile reaches the card below, no two tiles overlap.
final class TallGalleryTests: XCTestCase {
    private var app: XCUIApplication!
    private let shots = ["/app/chat-dark.webp", "/app/today-dark.webp", "/app/choose-dark.webp", "/app/chat-light.webp"]
    private let question = "Next for the composer?"

    private func check(_ layout: String, pick: Bool) {
        let tag = "\(layout)\(pick ? "-pick" : "")"
        let lines = [#"gallery "Where we are" "# + shots.joined(separator: " ") + " layout=\(layout)" + (pick ? " +pick" : ""),
                     #"ask "\#(question)" Files|"Voice notes as audio"|"Ship a TestFlight build""#]
        app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "wizard", "-appearance", "dark",
                               "-yuiDemoPrompt", "Show me the app", "-yuiDemoDelay", "0.5",
                               "-yuiThemeDemo", lines.joined(separator: "\\n")]
        app.launch()
        let card = app.staticTexts[question]
        XCTAssertTrue(card.waitForExistence(timeout: 20), "\(tag): the reply never arrived")
        sleep(3)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "tall-\(tag).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "tall-\(tag)"
        a.lifetime = .keepAlways
        add(a)
        let tiles = (1...shots.count).map { app.otherElements.matching(NSPredicate(format: "label == %@", "Item \($0)")) }
            .filter { $0.count > 0 }.map { $0.firstMatch.frame }.filter { !$0.isEmpty }
        XCTAssertGreaterThanOrEqual(tiles.count, 1, "\(tag): no photos")
        // row3d opens as its own screen over the chat; there the photos must stay
        // above the pick hint and Done instead of the question behind it.
        let below = card.isHittable ? card : app.staticTexts["Tap the circles to pick"]
        for (i, t) in tiles.enumerated() {
            if below.exists {
                XCTAssertLessThanOrEqual(t.maxY, below.frame.minY + 1, "\(tag): photo \(i + 1) runs under the next thing \(t) vs \(below.frame)")
            }
            for (j, u) in tiles.enumerated() where j > i {
                let o = t.intersection(u)
                XCTAssertTrue(o.isNull || o.width < 1 || o.height < 1, "\(tag): photos \(i + 1) and \(j + 1) overlap \(t) \(u)")
            }
        }
        app.terminate()
    }

    func testTallScreenshotsEveryLayout() throws {
        for layout in ["row", "row3d", "grid", "feed"] {
            check(layout, pick: false)
            check(layout, pick: true)
        }
    }
}
