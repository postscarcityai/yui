import XCTest
import YuiLines
@testable import Yui

/// Follow-ups to YUI-276: gesture marks over a mock (a tap, a swipe, an arrow, a doodle ring round a
/// part), short labels capped and fitted, and a drawing over a picture taking the picture's shape.
/// The numbers are what the hub's site/lib/yl/shapes.mjs gives for the same input.
@MainActor
final class GestureMarksTests: XCTestCase {
    private let tol = 2e-3

    private func near(_ a: [Double]?, _ b: [Double], _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let a, a.count == b.count else { XCTFail("\(what): \(String(describing: a)) vs \(b)", file: file, line: line); return }
        for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: tol, what, file: file, line: line) }
    }

    private func scene(_ yl: String, ratio: Double? = nil) throws -> ShapesModel.Scene {
        let screen = YLScreen(yl)
        let top = try XCTUnwrap(screen.top.first)
        let parts = top.preset == "shape" ? [top] : screen.components.members(of: top).filter { $0.preset == "shape" }
        return ShapesModel.scene(head: top.preset == "shape" ? [:] : top.props,
                                 members: parts.map { (id: $0.ylID, props: $0.props) }, ratio: ratio)
    }

    private let holdToTalk = """
    mock "Hold to talk"
    part@send button Send
    part@mic avatar M
    shape tap at=send
    shape swipe "slide to cancel" at=mic dir=left
    shape doodle at=send tone=butter
    shape arrow "tap here" from=1,1 to=send
    shape tap at=5,10
    """

    // MARK: Marks over a mock

    func testAMockHoldsItsMarks() throws {
        let yl = YLScreen(holdToTalk)
        let mock = try XCTUnwrap(yl.top.first)
        XCTAssertEqual(yl.top.map(\.preset), ["mock"], "the marks ride inside the mock")
        let members = yl.components.members(of: mock)
        XCTAssertEqual(members.map(\.preset), ["part", "part", "shape", "shape", "shape", "shape", "shape"])
        let parts = MockModel.parts(withIDs: members.filter { $0.preset == "part" }.map { (id: $0.ylID, props: $0.props) })
        XCTAssertEqual(parts.map(\.id), ["send", "mic"])
        let marks = members.filter { $0.preset == "shape" }.map { MockMark(id: $0.ylID, props: $0.props) }
        XCTAssertEqual(MockModel.describe(marks: marks, parts: parts),
                       "Marks: tap on Send; swipe on M, left, slide to cancel; doodle on Send; arrow on Send, tap here; tap.")
    }

    func testMarksFindThePartsTheyPointAt() throws {
        let yl = YLScreen(holdToTalk)
        let mock = try XCTUnwrap(yl.top.first)
        let marks = yl.components.members(of: mock).filter { $0.preset == "shape" }
        // A phone screen 300 by 500 points: Send's button across it, the mic in the middle under it.
        let sc = ShapesModel.marksOver(marks.map { (id: $0.ylID, props: $0.props) },
                                       cells: ["send": [16, 300, 268, 36], "mic": [130, 380, 40, 40]], box: [300, 500])
        XCTAssertEqual(sc.w, 10)
        XCTAssertEqual(sc.h, 16.6667, accuracy: tol, "as tall as the screen, past the usual 16")
        XCTAssertEqual(sc.items.map(\.kind), ["tap", "swipe", "doodle", "arrow", "tap"])
        near(sc.items[0].at, [5, 10.6], "a tap on Send lands in its middle")
        XCTAssertEqual(sc.items[1].from, .pt([5, 13.3333]), "the swipe starts on the mic")
        if case .pt(let p)? = sc.items[1].to { near(p, [2, 13.3333], "and runs three tenths of the screen to the left") }
        else { XCTFail("swipe end") }
        near(sc.items[2].pts?.first, [3.198, 9.6648], "the doodle rings the whole button")
        if case .pt(let p)? = sc.items[3].to { near(p, [4.67, 9.8631], "the arrow stops at the button's edge") }
        else { XCTFail("arrow end") }
        if case .pt(let p)? = sc.items[3].from { near(p, [1, 1.6667], "a free point is tenths of the screen") }
        else { XCTFail("arrow start") }
        near(sc.items[4].at, [5, 16.2167], "10,10 is the bottom, kept on the screen")
        XCTAssertEqual(ShapesModel.describe(sc), "tap, swipe, slide to cancel, tap here, tap")
    }

    func testATapLandsAndASwipeRunsItsWay() throws {
        let sc = try scene("shapes w=10 h=6\nshape tap \"hold to talk\" at=5,4.5 +pulse\nshape swipe at=5,4.5 dir=up\nshape swipe at=5,4.5 dir=sideways")
        XCTAssertEqual(sc.items.map(\.kind), ["tap", "swipe"], "a swipe with no way to go is not drawn")
        XCTAssertEqual(sc.items[0].motion, .grow)
        near(sc.items[0].size, [0.9, 0.9], "a fingertip")
        XCTAssertEqual(sc.items[1].motion, .draw)
        XCTAssertEqual(sc.items[1].to, .pt([5, 1.5]))
    }

    // MARK: Short labels

    func testShortLabelsAreCapped() {
        XCTAssertEqual(ShapesModel.cap("Product design team"), "Product design…")
        XCTAssertEqual(ShapesModel.cap("Supercalifragilisticexpialidocious"), "Supercalifragilis…")
        XCTAssertEqual(ShapesModel.cap("one two three four"), "one two three…")
        XCTAssertEqual(ShapesModel.cap("  a   b  "), "a b")
        XCTAssertEqual(ShapesModel.cap("Yui"), "Yui")
    }

    func testTheNewKindsCapTheirLabels() throws {
        let sc = try scene("shapes\nshape venn \"The people who design every screen\" sets=\"Product design team\"|Code\nshape box \"A box keeps its whole long label\"")
        XCTAssertEqual(sc.items[0].label, "The people who…")
        XCTAssertEqual(sc.items[0].sets, ["Product design…", "Code"])
        XCTAssertEqual(sc.items[1].label, "A box keeps its whole long label", "the old kinds are as they were")
    }

    func testALabelFitsInTwoLinesAndShrinksToAFloor() {
        let wide = ShapesModel.fit("Yui", width: 2, fs: 0.42)
        XCTAssertEqual(wide.lines, ["Yui"])
        XCTAssertEqual(wide.fs, 0.42, accuracy: tol)
        let tight = ShapesModel.fit("Mocks and prototypes", width: 0.9, fs: 0.42)
        XCTAssertEqual(tight.lines, ["Mocks", "and prototypes"], "never more than two lines")
        XCTAssertEqual(tight.fs, 0.294, accuracy: tol, "no smaller than 0.7 of its size")
    }

    // MARK: A picture's shape

    func testADrawingOverAPictureTakesItsShape() throws {
        XCTAssertEqual(try scene("shapes \"Fix this\" img=/demo/a.jpg\nshape dot", ratio: 2).h, 5, accuracy: tol)
        XCTAssertEqual(try scene("shapes \"Fix this\" img=/demo/a.jpg h=4\nshape dot", ratio: 2).h, 4, accuracy: tol, "h= wins")
        XCTAssertEqual(try scene("shapes \"Fix this\" img=/demo/a.jpg\nshape dot").h, 2, accuracy: tol, "the old default until it loads")
        XCTAssertEqual(try scene("shapes \"No picture\"\nshape dot", ratio: 2).h, 2, accuracy: tol, "no picture, no shape to take")
        XCTAssertTrue(ShapesModel.pictureShaped(["img": .string("/a.jpg")]))
        XCTAssertFalse(ShapesModel.pictureShaped(["img": .string("/a.jpg"), "h": .number(4)]))
    }
}
