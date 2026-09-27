import XCTest

/// Maps (YUI-158; Chris on the Mongol Empire answer, feedback AL2nKEYo: "Again,
/// not bad but this should be a Map."). `-yuiDemoMap` seeds three replies drawn
/// with `map`: the Mongol Empire with a pin and four ways out, a train trip whose
/// route stops at pins, and countries by code across the date line. Each map is
/// in the chat on a card, reads its places to VoiceOver in line order, and has its
/// caption under it. Then the explainer deck on the full-screen stage: the map is
/// the first page's picture, it pinches in, and the next page still turns.
/// Demo account, no network. Screenshots go to `YUI_SHOTS` when set.
final class MapTests: XCTestCase {
    func testLight() throws { try chat(appearance: "light", tag: "light") }
    func testDark() throws { try chat(appearance: "dark", tag: "dark") }
    func testReduceMotion() throws { try chat(appearance: "light", reduce: true, tag: "reduce") }
    func testStageLight() throws { try stage(appearance: "light") }
    func testStageDark() throws { try stage(appearance: "dark") }

    static let deck = """
    >full
    deck "The Mongols, by the map"
    page "How far it reached" body="Korea to Hungary, the Siberian forest to Persia."
    map caption="Karakorum sat in the middle and rode out every way."
    area Empire 53,140|43,131|38.5,128.5|34.7,126.5|37.5,122.5|31,121.8|25,119.5|22.3,114|20.5,110.2|21.8,108|22.5,103|24,98|28,97|28,86|30,80|34,74|34,70|30,66|26,62|25.5,57|28,51|30,48|33,44|36,38.5|37,36|36.5,32|41,31|41.5,41.5|45,37|46,30.5|48,27|50.5,24|54,23|57,28|60,31|62,40|60,56|58,65|56,80|55,95|53,108|55,120 tone=butter
    pin@ka Karakorum 47.2,102.8 +pulse
    route West ka|47.5,19 +arrow +dash
    page "The biggest one on land"
    chart bar "Land empires, million km2" x=Mongol|Russian|Qing|Roman y=24|22.8|14.7|5
    end
    """

    private func shot(_ name: String, _ tag: String) {
        let s = XCUIScreen.main.screenshot()
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "map-\(name)-\(tag).png"))
        }
        let a = XCTAttachment(screenshot: s)
        a.name = "map-\(name)-\(tag)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func drawing(_ app: XCUIApplication, _ starts: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'map-drawing' AND label BEGINSWITH %@", starts)).firstMatch
    }

    private func chat(appearance: String, reduce: Bool = false, tag: String) throws {
        let app = XCUIApplication()
        func scroll(up: Bool) {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: up ? 0.35 : 0.7))
            from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: up ? 0.7 : 0.35)))
        }
        func reveal(_ e: XCUIElement) {
            for _ in 0..<8 where !(e.exists && e.isHittable) { scroll(up: true) }
            for _ in 0..<8 where !(e.exists && e.isHittable) { scroll(up: false) }
        }
        var args = ["-yuiDemoAccount", "-yuiDemoMap", "-appearance", appearance]
        if reduce { args.append("-yuiReduceMotion") }
        app.launchArguments = args
        app.launch()

        // The newest reply: Russia and Alaska, one map across the date line.
        let bering = drawing(app, "Bering Strait")
        XCTAssertTrue(bering.waitForExistence(timeout: 15), "the map reply never reached the chat")
        XCTAssertEqual(bering.label, "Bering Strait. Map: Russia, United States of America; Anchorage; Magadan. Russia and Alaska are 82 km apart.")
        XCTAssertEqual(bering.value as? String, "3 parts")
        XCTAssertTrue(app.staticTexts["Russia and Alaska are 82 km apart."].exists, "no caption")
        shot("bering", tag)

        // A route through pins reads as the pins it stops at.
        let trip = drawing(app, "Lisbon to Rome by train")
        reveal(trip)
        XCTAssertTrue(trip.isHittable, "the trip is not on screen")
        XCTAssertEqual(trip.label, "Lisbon to Rome by train. Map: Iberia: Portugal, Spain; Lisbon; Madrid; Barcelona; Rome; A route, Lisbon to Madrid to Barcelona to Rome. Three nights, four trains.")
        shot("trip", tag)

        // The answer Chris flagged, as a map: the empire, the raids, Karakorum and four ways out.
        let mongols = drawing(app, "The Mongol Empire, 1279")
        reveal(mongols)
        XCTAssertTrue(mongols.isHittable, "the Mongol map is not on screen")
        XCTAssertEqual(mongols.label, "The Mongol Empire, 1279. Map: Mongol Empire; Raided: Poland, Hungary; Karakorum; East; West; South; North. 24M km². The biggest land empire there has been.")
        XCTAssertEqual(mongols.value as? String, "7 parts")
        XCTAssertTrue(app.staticTexts["At its peak, 1279, it ran from Korea to Hungary's edge."].exists, "no say line above it")
        if !reduce {
            // A tap plays it again: shoot it part way, then finished.
            mongols.tap()
            usleep(900_000)
            shot("mongols-mid", tag)
            sleep(3)
        }
        shot("mongols", tag)

        // No raw lines and no Update chip: this build draws maps.
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'area ' OR label BEGINSWITH 'route '")).firstMatch.exists,
                       "raw Yui Lines in the chat")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'update'")).firstMatch.exists, "an Update chip for maps")
    }

    private func stage(appearance: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemo", "-appearance", appearance, "-yuiDemoReply",
                               Self.deck.replacingOccurrences(of: "\n", with: "\\n")]
        app.launch()
        let field = app.descendants(matching: .any)["composer"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no composer")
        field.tap()
        field.typeText("Where did the Mongols rule?")
        app.buttons["Send"].tap()

        XCTAssertTrue(app.staticTexts["How far it reached"].waitForExistence(timeout: 20), "the deck never opened")
        let map = drawing(app, "Map: Empire")
        XCTAssertTrue(map.waitForExistence(timeout: 5), "the first page has no map")
        XCTAssertEqual(map.label, "Map: Empire; Karakorum; West. Karakorum sat in the middle and rode out every way.")
        sleep(3)
        shot("stage", appearance)

        // Pinch in on the stage; the page stays put.
        map.pinch(withScale: 1.6, velocity: 1)
        sleep(1)
        XCTAssertTrue(app.staticTexts["How far it reached"].exists, "pinching the map turned the page")
        shot("stage-zoomed", appearance)
        map.doubleTap()
        sleep(1)

        // At full size, the next page still turns.
        app.buttons["Next page"].tap()
        XCTAssertTrue(app.staticTexts["The biggest one on land"].waitForExistence(timeout: 5), "the deck did not turn past the map")
        shot("stage-next", appearance)
    }
}
