import XCTest

/// Pictures show whole (TestFlight feedback AM6xGDZ3, 2026-09-26: "we're not cutting
/// off screenshots or really any type of image. When displaying an image, we should
/// look at the size of the actual image and then create a box that big instead").
/// A portrait, a landscape and a very tall picture, each in `image`, a gallery and a
/// chat photo: every box has the picture's own shape. And the 3D row's cards got big.
final class WholePictureTests: XCTestCase {
    private var app: XCUIApplication!
    private var tag = ""
    private let portrait = "https://picsum.photos/id/1025/600/900.jpg"
    private let landscape = "https://picsum.photos/id/1018/1200/700.jpg"
    private let tall = "https://picsum.photos/id/1039/400/1600.jpg"

    private func launch(_ tag: String, _ lines: [String], photos: [String] = []) {
        self.tag = tag
        app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "wizard", "-appearance", "dark",
                               "-yuiDemoPrompt", "Show me the pictures", "-yuiDemoDelay", "0.5",
                               "-yuiThemeDemo", lines.joined(separator: "\\n")]
        if !photos.isEmpty { app.launchArguments += ["-yuiDemoPromptPhotos", photos.joined(separator: " ")] }
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

    private func element(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// The box is the picture's shape, within `accuracy` of width over height.
    private func assertShape(_ label: String, _ ratio: CGFloat, accuracy: CGFloat = 0.04, file: StaticString = #filePath, line: UInt = #line) {
        let e = element(label)
        XCTAssertTrue(e.waitForExistence(timeout: 20), "\(tag): \(label) never showed", file: file, line: line)
        let f = e.frame
        XCTAssertGreaterThan(f.height, 40, "\(tag): \(label) collapsed \(f)", file: file, line: line)
        XCTAssertEqual(f.width / f.height, ratio, accuracy: accuracy, "\(tag): \(label) is \(f), not the picture's shape", file: file, line: line)
        XCTAssertTrue(f.minX >= -1 && f.maxX <= app.frame.maxX + 1, "\(tag): \(label) runs off screen \(f)", file: file, line: line)
    }

    /// `image`: each picture in its own shape; the tall one is capped and narrows.
    func testImage() throws {
        launch("image", ["say Three shapes.", "image \(portrait) Portrait", "image \(landscape) Landscape", "image \(tall) Tall"])
        XCTAssertTrue(element("Portrait").waitForExistence(timeout: 20))
        sleep(4)
        shot("top")
        assertShape("Portrait", 600 / 900)
        assertShape("Landscape", 1200 / 700)
        app.swipeUp()
        sleep(2)
        assertShape("Tall", 400 / 1600)
        XCTAssertLessThanOrEqual(element("Tall").frame.height, 561, "\(tag): the tall one is not capped")
        shot("tall")
    }

    /// Feed and row galleries: tiles take each picture's shape.
    func testGallery() throws {
        launch("gallery-feed", [#"gallery "Three shapes" \#(portrait) \#(landscape) \#(tall) caps=Portrait|Landscape|Tall layout=feed"#])
        XCTAssertTrue(element("Portrait").waitForExistence(timeout: 20))
        sleep(4)
        shot("top")
        assertShape("Portrait", 600 / 900)
        assertShape("Landscape", 1200 / 700)
        app.terminate()

        launch("gallery-row", [#"gallery "Three shapes" \#(landscape) \#(portrait) \#(tall) caps=Landscape|Portrait|Tall"#])
        XCTAssertTrue(element("Landscape").waitForExistence(timeout: 20))
        sleep(4)
        shot("screen")
        // 200 tall; width from the shape, kept between 120 and 320. The row scrolls,
        // so only the first tile is sure to be on screen.
        assertShape("Landscape", 320 / 200)
        let second = element("Portrait").frame
        XCTAssertEqual(second.width / second.height, 600 / 900, accuracy: 0.04, "\(tag): Portrait is \(second), not its shape")
    }

    /// The 3D row from the screenshot: big cards in their own shape, the next peeking.
    func testRow3D() throws {
        launch("row3d", [#"gallery "Screens" \#(portrait) \#(portrait) \#(portrait) caps=One|Two|Three layout=row3d"#])
        let one = element("One")
        XCTAssertTrue(one.waitForExistence(timeout: 20))
        sleep(4)
        shot("screen")
        XCTAssertGreaterThan(one.frame.width, app.frame.width * 0.6, "\(tag): the card is still small \(one.frame)")
        XCTAssertEqual(one.frame.width / one.frame.height, 600 / 900, accuracy: 0.04, "\(tag): the card is not the picture's shape \(one.frame)")
        XCTAssertTrue(element("Two").exists, "\(tag): the next card does not peek")
    }

    /// Photos in the person's own bubble: the photo's shape, not a 200pt square.
    func testChatPhotos() throws {
        launch("chat-photo", ["say Got them."], photos: [portrait, landscape, tall])
        let photos = app.descendants(matching: .any).matching(identifier: "bubble-photo")
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 30), "\(tag): no photo in the bubble")
        sleep(3)
        shot("screen")
        let frames = (0..<photos.count).map { photos.element(boundBy: $0).frame }
        // The old 200pt square cropped a fill picture: its frame ran past the square
        // (the tall one 200x800). Now each fits a 220 wide, 320 tall box whole.
        for f in frames {
            XCTAssertLessThanOrEqual(f.width, 221, "\(tag): a photo is wider than its box \(f)")
            XCTAssertLessThanOrEqual(f.height, 321, "\(tag): a photo is taller than its box \(f)")
        }
        let shapes = frames.map { $0.width / $0.height }
        XCTAssertEqual(shapes.count, 3, "\(tag): \(shapes.count) photos, not 3")
        for want in [600.0 / 900, 1200.0 / 700, 400.0 / 1600] {
            XCTAssertTrue(shapes.contains { abs($0 - want) < 0.04 }, "\(tag): no photo shaped \(want), got \(shapes)")
        }
    }
}
