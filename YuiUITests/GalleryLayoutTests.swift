import XCTest

/// Gallery photos keep to their own space (TestFlight feedback, 2026-09-24: "The
/// photos are overlapping and it doesn't look nice"). A `+pick` gallery under the
/// reply's text drew its photos over that text and over Done. Each layout, at 1,
/// 2, 3, 4 and 7 photos: no tile covers another, the note above or the Done below.
final class GalleryLayoutTests: XCTestCase {
    private var app: XCUIApplication!
    private var tag = ""
    private let note = "Here they are, fresh from just now."
    private let urls = ["/demo/g1.jpg", "/demo/g2.jpg", "/demo/g3.jpg", "/demo/g4.jpg", "/demo/g5.jpg", "/demo/g6.jpg", "/demo/g1.jpg"]

    private func launch(_ tag: String, layout: String, count: Int) {
        self.tag = tag
        let items = urls.prefix(count).joined(separator: " ")
        let lines = ["say \(note)", #"gallery "Fresh renders" "# + items + " layout=\(layout) +pick"]
        app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "wizard", "-appearance", "dark",
                               "-yuiDemoPrompt", "Photo gallery", "-yuiDemoDelay", "0.5",
                               "-yuiThemeDemo", lines.joined(separator: "\\n")]
        app.launch()
    }

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

    /// Streams the reply, checks the frames and returns them for per-layout checks.
    private func check(_ layout: String, _ count: Int) -> [CGRect] {
        launch("\(layout)-\(count)", layout: layout, count: count)
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 20), "\(tag): the gallery never arrived")
        sleep(2)
        shot("screen")
        let text = app.staticTexts[note]
        let hint = app.staticTexts["Tap the circles to pick"]
        XCTAssertTrue(text.exists, "\(tag): the note is missing")
        // The row and grid are lazy: photos past the edge are not built yet. The
        // row always shows its first two, every other layout all of them.
        let tiles = (1...count).map { app.otherElements.matching(NSPredicate(format: "label == %@", "Item \($0)")) }
            .filter { $0.count > 0 }.map { $0.firstMatch.frame }
        XCTAssertGreaterThanOrEqual(tiles.count, layout == "row" ? min(count, 2) : count, "\(tag): photos missing")
        XCTAssertFalse(tiles.contains(where: \.isEmpty), "\(tag): a tile has no frame")
        for (i, t) in tiles.enumerated() {
            XCTAssertGreaterThanOrEqual(t.minY, text.frame.maxY - 1, "\(tag): photo \(i + 1) covers the note \(t) vs \(text.frame)")
            if hint.exists { XCTAssertLessThanOrEqual(t.maxY, hint.frame.minY + 1, "\(tag): photo \(i + 1) covers the hint \(t) vs \(hint.frame)") }
            XCTAssertLessThanOrEqual(t.maxY, done.frame.minY + 1, "\(tag): photo \(i + 1) covers Done \(t) vs \(done.frame)")
            for (j, u) in tiles.enumerated() where j > i {
                let o = t.intersection(u)
                XCTAssertTrue(o.isNull || o.width < 1 || o.height < 1, "\(tag): photos \(i + 1) and \(j + 1) overlap \(t) \(u)")
            }
        }
        return tiles
    }

    /// The default row, the screen Chris was on: 230x170 tiles side by side.
    func testRow() throws {
        for n in [1, 2, 3, 4, 7] {
            let tiles = check("row", n)
            for t in tiles {
                XCTAssertEqual(t.height, 170, accuracy: 1, "row-\(n): a tile is \(t.height)pt tall, not 170")
                XCTAssertEqual(t.width, 230, accuracy: 1, "row-\(n): a tile is \(t.width)pt wide, not 230")
            }
            XCTAssertGreaterThanOrEqual(tiles[0].minX, 0, "row-\(n): the first photo starts off screen")
            app.terminate()
        }
    }

    /// Three square columns, inside the screen.
    func testGrid() throws {
        for n in [1, 2, 3, 4, 7] {
            let tiles = check("grid", n)
            for t in tiles {
                XCTAssertEqual(t.width, t.height, accuracy: 1.5, "grid-\(n): a tile is not square \(t)")
                XCTAssertGreaterThan(t.width, 60, "grid-\(n): a tile collapsed \(t)")
                XCTAssertTrue(t.minX >= 0 && t.maxX <= app.frame.maxX, "grid-\(n): a tile runs off screen \(t)")
            }
            app.terminate()
        }
    }

    /// Full-width 4:3 photos, one under the other.
    func testFeed() throws {
        for n in [1, 2, 4] {
            let tiles = check("feed", n)
            for t in tiles {
                XCTAssertEqual(t.width / t.height, 4 / 3, accuracy: 0.03, "feed-\(n): a tile is not 4:3 \(t)")
                XCTAssertGreaterThan(t.width, app.frame.width * 0.6, "feed-\(n): a tile shrank to a thumbnail \(t)")
                XCTAssertTrue(t.minX >= 0 && t.maxX <= app.frame.maxX, "feed-\(n): a tile runs off screen \(t)")
            }
            app.terminate()
        }
    }
}
