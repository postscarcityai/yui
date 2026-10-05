import XCTest
import YuiLines
@testable import Yui

/// Draw anything on any screen (YUI-276): Venns, contours, regions, doodles, bent arrows and marks over
/// a picture, as `shape` kinds. The numbers are what the hub's site/lib/yl/shapes.mjs gives for the
/// same lines (the scene itself is checked in ShapesSceneTests against shapes-scenes.json).
@MainActor
final class ShapesMarksTests: XCTestCase {
    private let tol = 2e-3

    private func scene(_ yl: String) throws -> ShapesModel.Scene {
        let screen = YLScreen(yl)
        let top = try XCTUnwrap(screen.top.first)
        let parts = top.preset == "shape" ? [top] : screen.components.members(of: top).filter { $0.preset == "shape" }
        return ShapesModel.scene(head: top.preset == "shape" ? [:] : top.props, members: parts.map { (id: $0.ylID, props: $0.props) })
    }

    private func near(_ a: [Double]?, _ b: [Double], _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let a, a.count == b.count else { XCTFail("\(what): \(String(describing: a)) vs \(b)", file: file, line: line); return }
        for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: tol, what, file: file, line: line) }
    }

    func testAVennOfTwoLabelsEachSetAndTheOverlap() throws {
        let sc = try scene("shapes w=12 h=5\nshape venn Yui sets=Chat|Drawing at=3.2,2.5")
        let it = try XCTUnwrap(sc.items.first)
        XCTAssertTrue(it.fill, "a Venn is always washed, so the overlap reads darker")
        let v = ShapesModel.venn(it, center: try XCTUnwrap(it.at), fs: sc.fs)
        XCTAssertEqual(v.circles.map(\.tone), ["accent", "mint"])
        near(v.circles[0].c, [2.24, 2.5], "left circle")
        near(v.circles[1].c, [4.16, 2.5], "right circle")
        XCTAssertEqual(v.circles[0].r, 1.6, accuracy: tol)
        XCTAssertEqual(v.labels.map(\.text), ["Chat", "Drawing", "Yui"])
        // Each name in the widest part of its own region: the middle of each crescent, the middle of the lens.
        near(v.labels[0].at, [1.6095, 2.5], "Chat")
        near(v.labels[1].at, [4.7905, 2.5], "Drawing")
        near(v.labels[2].at, [3.2, 2.5], "the overlap")
        XCTAssertTrue(v.labels[2].middle)
        XCTAssertEqual(v.labels[2].width, 1.1044, accuracy: tol)
        XCTAssertEqual(v.labels.map(\.lines), [["Chat"], ["Drawing"], ["Yui"]])
        XCTAssertEqual(v.labels[0].fs, 0.4284, accuracy: tol, "set names at 0.85 of the label size")
        XCTAssertEqual(ShapesModel.describe(sc), "Chat and Drawing overlap: Yui")
    }

    func testAVennOfThreeLabelsItsPairs() throws {
        let sc = try scene("shapes w=12 h=5\nshape venn All sets=Design|Code|Words pairs=Mock|Sketch|Docs at=9,2.5 size=4.6 tone=mint")
        let it = try XCTUnwrap(sc.items.first)
        near(it.size, [4.6, 4.37], "three sets keep a rounder box")
        let v = ShapesModel.venn(it, center: try XCTUnwrap(it.at), fs: sc.fs)
        XCTAssertEqual(v.circles.map(\.tone), ["mint", "lavender", "butter"])
        near(v.circles[2].c, [9, 3.2469], "bottom circle")
        XCTAssertEqual(v.labels.map(\.text), ["Design", "Code", "Words", "All", "Mock", "Sketch", "Docs"])
        near(v.labels[3].at, [9, 2.1685], "where all three overlap")
        near(v.labels[4].at, [9, 1.5231], "Design and Code")
        near(v.labels[5].at, [8.2071, 2.8315], "Design and Words")
        // A pair's part is small: its name shrinks, down to the floor, and stays whole.
        XCTAssertEqual(v.labels[5].lines, ["Sketch"])
        XCTAssertEqual(v.labels[5].fs, 0.2999, accuracy: tol)
    }

    func testAOneSetVennReadsAsItsName() throws {
        let sc = try scene("shape venn sets=Ask")
        XCTAssertEqual(sc.items.first?.sets, ["Ask"])
        XCTAssertEqual(ShapesModel.describe(sc), "Ask")
    }

    func testAContourDriftsItsRingsToThePeak() throws {
        let sc = try scene("shapes\nshape@hot contour Peak at=6,3 size=3.4,2.6 rings=5 +fill")
        let it = try XCTUnwrap(sc.items.first)
        XCTAssertEqual(it.rings, 5)
        XCTAssertEqual(it.motion, .draw, "rings trace themselves on")
        let c = ShapesModel.contour(it, center: try XCTUnwrap(it.at))
        XCTAssertEqual(c.rings.count, 5)
        near(c.peak, [6.009, 2.8545], "peak")
        near(c.rings[0].first, [6, 1.7127], "outer ring")
        near(c.rings[4].first, [6.009, 2.5971], "inner ring")
        XCTAssertEqual(try scene("shape contour rings=40").items.first?.rings, 8, "at most eight rings")
    }

    func testADoodleWobblesTheSameWayEveryTime() {
        let d = ShapesModel.doodle([[9, 7], [11, 6.2], [13, 6.8]], seed: 1, w: 16)
        XCTAssertEqual(d.count, 9)
        near(d.first, [9, 7], "it starts where it was told")
        near(d[1], [9.3336, 6.7719], "a nudged sample")
        near(d[5], [11.5315, 6.335], "another")
        near(d.last, [13, 6.8], "and ends there")
        XCTAssertEqual(d, ShapesModel.doodle([[9, 7], [11, 6.2], [13, 6.8]], seed: 1, w: 16))
    }

    func testADoodleWithAPlaceIsARingRoundIt() throws {
        let sc = try scene("shape doodle at=5,3")
        let pts = try XCTUnwrap(sc.items.first?.pts)
        XCTAssertEqual(pts.count, 10)
        near(pts[0], [4.5672, 2.2713], "first guide point")
        near(pts[1], [5.4564, 2.2901], "second")
        XCTAssertEqual(sc.h, 6, accuracy: tol, "a drawn mark keeps the full canvas")
    }

    func testARegionNeedsThreePointsAndABendIsClamped() throws {
        let sc = try scene("shapes\nshape region A pts=1,1|2,1|2,2\nshape region B pts=1,1|2,2\nshape arrow from=1,1 to=3,1 bend=5")
        XCTAssertEqual(sc.items.map(\.kind), ["region", "arrow"])
        XCTAssertEqual(sc.items.first?.fill, false)
        XCTAssertEqual(sc.items.last?.bend, 2)
    }

    func testABentArrowRunsThroughItsControlPoint() throws {
        let sc = try scene("shapes w=10 h=6\nshape arrow from=1,3 to=9,3 bend=0.25")
        let f = try XCTUnwrap(ShapesModel.frame(sc, at: .infinity).first)
        near(f.a.flatMap { a in f.b.map { ShapesModel.control(a, $0, 0.25) } }, [5, -1], "the middle stands off a quarter of the length, to the left of the way it goes")
        let mid = ShapesModel.bent([0, 0], [5, -5], [10, 0], 0.5)
        near(mid.p, [5, -2.5], "halfway")
        near(mid.dir, [10, 0], "heading")
    }

    /// Any screen: a plan takes a drawing as a page's picture, in the flow and on the stage, as a deck does.
    func testAPlanTakesShapesAsAPagesPicture() throws {
        let yl = YLScreen("plan P\npage One\nshapes\nshape venn Yui sets=Chat|Drawing\npage Two")
        let plan = try XCTUnwrap(yl.top.first)
        XCTAssertEqual(yl.top.map(\.preset), ["plan"], "the drawing rides inside the plan")
        let steps = yl.components.steps(of: plan)
        XCTAssertEqual(steps.map(\.preset), ["page", "page"])
        XCTAssertEqual(yl.components.picture(of: steps[0])?.preset, "shapes")
        XCTAssertEqual(StageChunks.of(yl, scope: "r").chunks.map { $0.pic?.preset }, ["shapes", nil])
    }

    func testAPictureGoesUnderTheDrawing() throws {
        let sc = try scene("shapes \"Fix this\" img=/demo/site_before_hero.jpg w=16 h=9\nshape doodle at=5,3 size=4,2 tone=butter")
        XCTAssertEqual(sc.img, "/demo/site_before_hero.jpg")
        XCTAssertNotNil(YLMediaURL.url(sc.img))
        XCTAssertEqual(try scene("shapes\nshape dot").img, "")
    }
}
