import XCTest
import YuiLines
@testable import Yui

/// A sketch on a story page (YUI-84, spec: sketch, On a page): inside a deck or plan
/// a sketch is the picture of the page right before it, and one with no page there
/// is a page of its own. Rows ride inside the sketch, never loose on the screen.
@MainActor
final class SketchStepsTests: XCTestCase {
    func testASketchIsThePictureOfThePageBeforeIt() throws {
        let yl = YLScreen(ChatView.drawnPages)
        XCTAssertEqual(yl.top.map(\.preset), ["deck", "sketch"], "rows and the deck's sketches ride inside their heads")
        let deck = try XCTUnwrap(yl.top.first)
        let steps = yl.components.steps(of: deck)
        XCTAssertEqual(steps.map(\.preset), ["page", "page"])
        XCTAssertEqual(steps.map { $0.string("title") }, ["No card or feedback ids", "Every button does something"])
        let art = try XCTUnwrap(yl.components.art(of: steps[0]))
        XCTAssertEqual(art.sketch.string("frame"), "bubble")
        XCTAssertEqual(art.parts.map(\.preset), ["row", "after", "row"])
        XCTAssertEqual(art.parts.first?.flag("x"), true)
        XCTAssertEqual(art.parts.last?.flag("hi"), true)
        XCTAssertEqual(yl.components.art(of: steps[1])?.sketch.string("frame"), "phone")
        XCTAssertEqual(yl.components.art(of: steps[1])?.parts.count, 4)
    }

    func testASketchWithNoPageBeforeItIsAPage() throws {
        let yl = YLScreen("""
            plan "Look" +inline
            sketch First
            row A +x
            page Words
            sketch Second
            sketch Third
            choose@c "Keep it?" Yes|No
            """)
        let plan = try XCTUnwrap(yl.top.first)
        let steps = yl.components.steps(of: plan)
        XCTAssertEqual(steps.map(\.preset), ["page", "page", "page", "choose"])
        XCTAssertEqual(steps.map { yl.components.art(of: $0)?.sketch.string("title") }, ["First", "Second", "Third", nil],
                       "a page takes one sketch; the next one is a page of its own")
        XCTAssertEqual(steps[1].string("title"), "Words")
        XCTAssertNil(steps[0].string("title"), "a drawing-only page has no words of its own")
        XCTAssertEqual(yl.components.members(of: plan).count, 5, "members still list the sketches as they came")
    }

    func testRowsOutsideASketchStandAlone() {
        let yl = YLScreen("row Alone +hi\nafter")
        XCTAssertEqual(yl.top.map(\.preset), ["row", "after"])
    }
}
