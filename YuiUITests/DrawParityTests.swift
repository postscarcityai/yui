import XCTest

/// Every drawing-kit sample on the phone, side by side with the hub (YUI-302). The three samples are the
/// hub's `drawkit`, `drawkit-plan` and `handdrawn` presets (site/lib/yl/samples.mjs), page by page. Each
/// page is a `shapes` drawing that reads its parts to VoiceOver, so the test asserts every shape label is
/// there and the part count matches the lines of the sample. A later look change cannot drop a shape
/// silently. Demo account, no network. `YUI_SHOTS=<dir>` saves a shot of each page (dark and light).
///
/// Parity table (sample | phone | hub | fixed?), build 522 plus origin/main d6b954b, dark then light, shots in
/// the card's artifacts folder. Spacing and colour stay as they are (YUI-267 owns the look: the light tones
/// are paler on the phone than on the hub, left alone on purpose).
///   drawkit p1  Venn, three washes, blended middle ... Code, Words, Yui labels missing | all four | fixed: first page stalled
///   drawkit p2  contour, dot, flood zone, callout .... zone open, no wash              | closed, washed | fixed: path +close +fill
///   drawkit p3  annotated feed, callouts, bracket .... same                            | same           | -
///   drawkit p4  loop of three arcs ................... same                            | same           | -
///   drawkit-plan  Venn as a plan page ................ same                            | same           | -
///   handdrawn p1  plain vs +hand box, circle, blob ... circle and blob never drawn     | all six        | fixed: first page stalled
///   handdrawn p2  scribble, underline, check, arrow .. same                            | same           | -
/// The stall: a drawing mounted before its page was on screen ran its clock unseen, the TimelineView paused
/// on `finished`, and the canvas kept the last frame it ticked (a deck's first page froze at 0.7 to 1.2 s).
/// A finished drawing now draws its end state (ShapesCanvas).
final class DrawParityTests: XCTestCase {
    struct Page {
        let labels: [String]
        let parts: Int
    }

    struct Sample {
        let name: String
        let lines: [String]
        let pages: [Page]
    }

    static let drawkit = Sample(
        name: "drawkit",
        lines: [
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
        ],
        pages: [
            Page(labels: ["Design", "Code", "Words", "Yui"], parts: 7),
            Page(labels: ["Peak", "Flood zone"], parts: 4),
            Page(labels: ["Search", "Card", "Tabs", "Starts here", "Swipe to dismiss", "Feed"], parts: 8),
            Page(labels: ["Ask", "Build", "Ship"], parts: 6),
        ])

    static let plan = Sample(
        name: "drawkit-plan",
        lines: [
            ">full",
            "plan \"Pick the overlap\" submit=Send",
            "page \"Where does it fit?\" body=\"Your idea sits between what you like and what pays.\"",
            "shapes w=10 h=6.4 caption=\"The middle is the one to build.\"",
            "shape circle at=3.7,3 size=4.4 tone=accent +fill +draw",
            "shape circle at=6.3,3 size=4.4 tone=mint +fill +draw",
            "shape text \"Likes\" at=2.6,3",
            "shape text \"Pays\" at=7.4,3",
            "shape text \"Build\" at=5,3",
            "choose@pick \"Build it?\" Yes|Later",
            "end",
        ],
        pages: [Page(labels: ["Likes", "Pays", "Build"], parts: 5)])

    static let hand = Sample(
        name: "handdrawn",
        lines: [
            "deck \"Mark it by hand\"",
            "page \"Draw it like a sketch\" body=\"+hand wobbles a stroke. The same line wobbles the same on the phone and the web.\"",
            "shapes w=10 h=5 caption=\"Same three parts, plain then hand drawn.\"",
            "shape@a box Plain at=2.2,1.4 size=3,1.3",
            "shape@b box Sketch at=2.2,3.6 size=3,1.3 +hand",
            "shape circle Plain at=6,1.4 size=1.6 tone=mint",
            "shape circle Sketch at=6,3.6 size=1.6 tone=mint +hand",
            "shape@c blob Blob at=8.7,1.4 size=2,1.6 tone=lavender +fill",
            "shape blob Blob at=8.7,3.6 size=2,1.6 tone=lavender +fill +hand",
            "page \"Mark the spot\" body=\"A scribble rings or fills a place. An underline sits under a shape. A check ticks it off.\"",
            "shapes w=10 h=5 caption=\"Look here, this one, done.\"",
            "shape@card box \"Pricing page\" at=3,1.2 size=4,1.2 +hand",
            "shape scribble to=card",
            "shape@word text \"Ship it today\" at=3,2.9 size=4,0.8",
            "shape underline to=word tone=butter",
            "shape@task pill \"Fix the login\" at=3,4.1 size=4,0.9 +hand",
            "shape check to=task",
            "shape scribble at=8,2.6 size=2.4,2.6 tone=lavender +fill",
            "shape arrow from=5.6,1.4 to=6.8,2.3 +hand",
            "end",
        ],
        pages: [
            Page(labels: ["Plain", "Sketch", "Blob"], parts: 6),
            Page(labels: ["Pricing page", "Ship it today", "Fix the login"], parts: 8),
        ])

    func testDrawKitDark() throws { try walk(Self.drawkit, "dark") }
    func testDrawKitLight() throws { try walk(Self.drawkit, "light") }
    func testPlanDark() throws { try walk(Self.plan, "dark") }
    func testPlanLight() throws { try walk(Self.plan, "light") }
    func testHandDrawnDark() throws { try walk(Self.hand, "dark") }
    func testHandDrawnLight() throws { try walk(Self.hand, "light") }

    private func walk(_ sample: Sample, _ appearance: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "yui",
                               "-appearance", appearance, "-yuiDemoReply", sample.lines.joined(separator: "\\n"),
                               "-yuiDemoPickupAfter", "0.5", "-yuiDemoReplyAfter", "3.5"]
        app.launch()
        XCTAssertTrue(app.buttons["stage-type"].waitForExistence(timeout: 15), "no stage")
        app.buttons["stage-type"].tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Show me the \(sample.name) sample")
        app.buttons["stage-send-text"].tap()
        let drawing = app.descendants(matching: .any).matching(identifier: "shapes-drawing").firstMatch
        XCTAssertTrue(drawing.waitForExistence(timeout: 25), "\(sample.name): the first drawing never showed")
        for (i, page) in sample.pages.enumerated() {
            if i > 0 {
                let next = app.buttons["stage-next"]
                XCTAssertTrue(next.waitForExistence(timeout: 10), "\(sample.name): no next page")
                next.tap()
            }
            sleep(6)
            let d = app.descendants(matching: .any).matching(identifier: "shapes-drawing").firstMatch
            XCTAssertTrue(d.waitForExistence(timeout: 10), "\(sample.name) p\(i + 1): no drawing")
            for label in page.labels {
                XCTAssertTrue(d.label.contains(label), "\(sample.name) p\(i + 1): '\(label)' is missing from \(d.label)")
            }
            XCTAssertEqual(d.value as? String, "\(page.parts) parts", "\(sample.name) p\(i + 1): shapes dropped")
            shot("\(sample.name)-p\(i + 1)", appearance)
        }
    }

    private func shot(_ name: String, _ appearance: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "parity-\(name)-\(appearance).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "parity-\(name)-\(appearance)"
        a.lifetime = .keepAlways
        add(a)
    }
}
