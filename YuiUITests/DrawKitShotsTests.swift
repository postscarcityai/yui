import XCTest

/// The drawing kit on the phone (YUI-297): the deck from the hub's drawing-kit sample, page 3 (callouts and a
/// bracket) and page 4 (arcs) as the playground draws them. Demo account, no network.
/// `YUI_SHOTS=<dir>` saves the screenshots (dark and light).
final class DrawKitShotsTests: XCTestCase {
    private static let lines = [
            "deck \"Draw anything\"",
            "page \"Where circles cross\" body=\"Filled shapes blend where they meet. The word in the middle names the overlap.\"",
            "shapes w=10 h=7 caption=\"Three circles, three washes, one middle.\"",
            "shape circle at=3.8,2.6 size=4 tone=accent +fill +draw",
            "shape circle at=6.2,2.6 size=4 tone=mint +fill +draw",
            "shape circle at=5,4.6 size=4 tone=lavender +fill +draw",
            "shape text Design at=2.8,2.1",
            "shape text Code at=7.2,2.1",
            "shape text Words at=5,5.9",
            "shape text Yui at=5,3.5",
            "page \"Lines of equal height\" body=\"Nested closed rings from a center. Add a zone, a dot and a callout.\"",
            "shapes w=10 h=6 caption=\"A hill, a flood zone, and the one place to look.\"",
            "shape contour at=4.4,3 size=7,4.8 rings=6 tone=mint +fill",
            "shape dot Peak at=4.4,3 tone=accent",
            "shape path pts=7,0.8|9.2,1.4|9.4,3|8,3.8|6.9,2.4 +close +fill +dash tone=butter",
            "shape callout \"Flood zone\" at=8.2,5.2 to=8.3,2.6 tone=butter",
            "page \"Mark up a screen\" body=\"Boxes make the phone. Callouts point at parts, a bracket spans a group.\"",
            "shapes w=10 h=6 caption=\"A feed screen, annotated.\"",
            "shape box at=4.6,3 size=3.4,5.4 tone=mute",
            "shape pill Search at=4.6,0.9 size=2.8,0.7 +fill",
            "shape box Card at=4.6,2.3 size=2.8,1.1 +fill tone=lavender",
            "shape box Card at=4.6,3.7 size=2.8,1.1 +fill tone=lavender",
            "shape pill Tabs at=4.6,5.1 size=2.8,0.6 +fill tone=mint",
            "shape callout \"Starts here\" at=8.3,0.9 to=6,0.9 tone=accent",
            "shape callout \"Swipe to dismiss\" at=8.3,3 to=6,3.2 tone=butter",
            "shape bracket from=2.6,1.5 to=2.6,4.5 label=Feed tone=mute",
            "page \"Round and round\" body=\"Arrows bend. Three steps and the loop closes.\"",
            "shapes w=10 h=6 caption=\"Ask, build, ship. Then you ask again.\"",
            "shape@ask circle Ask at=5,1.2 size=1.8 +fill +grow",
            "shape@build circle Build at=8,4.6 size=1.8 +fill tone=mint +grow",
            "shape@ship circle Ship at=2,4.6 size=1.8 +fill tone=lavender +grow",
            "shape arc from=ask to=build",
            "shape arc from=build to=ship",
            "shape arc from=ship to=ask",
            "end",
    ]

    func testPagesThreeAndFourDark() throws { try pages("dark") }
    func testPagesThreeAndFourLight() throws { try pages("light") }

    private func pages(_ appearance: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "yui",
                               "-appearance", appearance, "-yuiDemoReply", Self.lines.joined(separator: "\\n"),
                               "-yuiDemoPickupAfter", "0.5", "-yuiDemoReplyAfter", "3.5"]
        app.launch()
        XCTAssertTrue(app.buttons["stage-type"].waitForExistence(timeout: 15), "no stage")
        app.buttons["stage-type"].tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Show me the drawing kit")
        app.buttons["stage-send-text"].tap()
        let next = app.buttons["stage-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 20), "the deck never played")
        sleep(2)
        for page in 2...4 {
            next.tap()
            sleep(5)
            if page >= 3 { shot("p\(page)", appearance) }
        }
    }

    private func shot(_ name: String, _ appearance: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "drawkit-\(name)-\(appearance).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "drawkit-\(name)-\(appearance)"
        a.lifetime = .keepAlways
        add(a)
    }
}
