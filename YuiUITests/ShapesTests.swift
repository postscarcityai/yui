import XCTest

/// Shapes that move (YUI-104; Chris on build 96: "simple SVG style vector graphics...
/// to show some complex ideas very quickly... still just in the chat with captions").
/// `-yuiDemoShapes` seeds four replies drawn with `shapes`: a flow in one row, a crowded
/// row whose labels wrap, placed shapes with a dashed arrow, and a card that glides to
/// the next column. Each drawing is in the chat on a card, reads its parts to VoiceOver
/// in order, and has its caption under it. Mid-animation and finished shots in light
/// and dark; under Reduce Motion the finished drawing is there at once.
/// Demo account, no network. Screenshots go to `YUI_SHOTS` when set.
final class ShapesTests: XCTestCase {
    func testLight() throws { try run(appearance: "light", tag: "light") }
    func testDark() throws { try run(appearance: "dark", tag: "dark") }
    func testReduceMotion() throws { try run(appearance: "light", reduce: true, tag: "reduce") }

    private func run(appearance: String, reduce: Bool = false, tag: String) throws {
        let app = XCUIApplication()
        let shots = ProcessInfo.processInfo.environment["YUI_SHOTS"].map { URL(fileURLWithPath: $0) }
        func shot(_ name: String) {
            let s = XCUIScreen.main.screenshot()
            if let shots { try? s.pngRepresentation.write(to: shots.appending(path: "shapes-\(name)-\(tag).png")) }
            let a = XCTAttachment(screenshot: s)
            a.name = "shapes-\(name)-\(tag)"
            a.lifetime = .keepAlways
            add(a)
        }
        func drawing(_ starts: String) -> XCUIElement {
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == 'shapes-drawing' AND label BEGINSWITH %@", starts)).firstMatch
        }
        func scroll(up: Bool) {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: up ? 0.35 : 0.7))
            from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: up ? 0.7 : 0.35)))
        }
        func reveal(_ e: XCUIElement) {
            for _ in 0..<8 where !(e.exists && e.isHittable) { scroll(up: true) }
            for _ in 0..<8 where !(e.exists && e.isHittable) { scroll(up: false) }
        }

        var args = ["-yuiDemoAccount", "-yuiDemoShapes", "-appearance", appearance]
        if reduce { args.append("-yuiReduceMotion") }
        app.launchArguments = args
        app.launch()

        // The newest reply: the card gliding to Running, then its caption.
        let trip = drawing("Where your idea is")
        XCTAssertTrue(trip.waitForExistence(timeout: 15), "the shapes reply never reached the chat")
        XCTAssertEqual(trip.label, "Where your idea is. Backlog, Running, Shipped, Shapes. Your shapes idea left the backlog. A lane is building it now.")
        XCTAssertEqual(trip.value as? String, "7 parts")
        XCTAssertTrue(app.staticTexts["Your shapes idea left the backlog. A lane is building it now."].exists, "no caption")
        shot("trip")

        // The flow in one row: every part in line order, read as one chain.
        let ask = drawing("How an ask reaches your phone")
        reveal(ask)
        XCTAssertTrue(ask.isHittable, "the flow is not on screen")
        XCTAssertEqual(ask.label, "How an ask reaches your phone. You → Board → Lane → Phone (ships). You ask, it lands on the board, a lane builds it, and it ships to your phone.")
        if !reduce {
            // Tap plays it again: shoot it part way, then finished.
            ask.tap()
            usleep(700_000)
            shot("ask-mid")
            sleep(3)
        }
        shot("ask")

        // The crowded row: labels wrap inside their shapes, the say line above it.
        let heat = drawing("Heat pump loop")
        reveal(heat)
        XCTAssertTrue(heat.isHittable, "the heat pump is not on screen")
        XCTAssertEqual(heat.label, "Heat pump loop. Outside air → Outdoor coil → Compressor → Indoor coil. Refrigerant colder than the outdoor air soaks up heat, the compressor squeezes it hot, and the indoor coil lets it out into the house.")
        XCTAssertTrue(app.staticTexts["Cold air still holds heat. The pump grabs it, squeezes it hot, and lets it out inside."].exists)
        shot("heat")

        // Placed shapes, a dashed arrow, a blob.
        let pic = drawing("Picture or shapes")
        reveal(pic)
        XCTAssertTrue(pic.isHittable, "the placed drawing is not on screen")
        XCTAssertEqual(pic.value as? String, "6 parts")
        shot("picture")

        // No raw lines and no Update chip: this build draws shapes.
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'shape '")).firstMatch.exists, "raw Yui Lines in the chat")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'update'")).firstMatch.exists, "an Update chip for shapes")
    }
}
