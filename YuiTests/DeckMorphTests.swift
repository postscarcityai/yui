import XCTest
import YuiLines
@testable import Yui

/// Decks that morph (TestFlight feedback ANhbech_, Oct 5): the shape matcher pairs a page's shapes with
/// the next page's, and the tween takes every pair from one page's drawing to the next's.
final class DeckMorphTests: XCTestCase {
    private func shape(_ id: String?, _ kind: String, _ label: String? = nil, _ extra: [String: YLValue] = [:]) -> (id: String?, props: [String: YLValue]) {
        var p: [String: YLValue] = ["kind": .string(kind)]
        if let label { p["label"] = .string(label) }
        p.merge(extra) { _, b in b }
        return (id, p)
    }

    private func page(_ members: [(id: String?, props: [String: YLValue])], head: [String: YLValue] = [:]) -> DeckMorph.Page {
        let sc = ShapesModel.scene(head: head, members: members)
        guard let p = DeckMorph.page(sc) else { XCTFail("no page"); return DeckMorph.Page(glyphs: [], bounds: [0, 0, 1, 1], fs: 1, lw: 1) }
        return p
    }

    private func g(_ key: String?, _ kind: String, _ label: String, closed: Bool = true) -> DeckMorph.Glyph {
        DeckMorph.Glyph(key: key, kind: kind, label: label, tone: "accent", closed: closed,
                        pts: closed ? DeckMorph.loop(DeckMorph.outline("circle", [1, 1], seed: 0)) : [[0, 0], [1, 0]],
                        center: [0, 0], labelAt: [0, 0], labelWidth: 1)
    }

    // MARK: the matcher

    func testIdWinsOverLabel() {
        let a = [g("s", "circle", "Dot"), g(nil, "box", "String")]
        let b = [g(nil, "circle", "Dot"), g("s", "blob", "Loop")]
        let m = DeckMorph.match(a, b)
        XCTAssertTrue(m.contains(.init(a: 0, b: 1)), "the @id pairs across kinds and labels: \(m)")
        XCTAssertTrue(m.contains(.init(a: nil, b: 0)), "Dot is taken by its @id elsewhere, so the new Dot arrives: \(m)")
        XCTAssertTrue(m.contains(.init(a: 1, b: nil)), "String has no partner and leaves: \(m)")
    }

    func testSameLabelMatchesIgnoringCase() {
        let m = DeckMorph.match([g(nil, "circle", "Light"), g(nil, "box", "Gravity")], [g(nil, "pill", "gravity"), g(nil, "blob", "light ")])
        XCTAssertEqual(Set(m.map { "\($0.a ?? -1)>\($0.b ?? -1)" }), ["0>1", "1>0"])
    }

    func testUnlabelledPairByFamilyInOrder() {
        let a = [g(nil, "circle", ""), g(nil, "arrow", "", closed: false), g(nil, "path", "", closed: false)]
        let b = [g(nil, "path", "", closed: false), g(nil, "box", ""), g(nil, "line", "", closed: false)]
        let m = DeckMorph.match(a, b)
        XCTAssertTrue(m.contains(.init(a: 0, b: 1)), "closed to closed: \(m)")
        XCTAssertTrue(m.contains(.init(a: 1, b: 2)), "connector to connector: \(m)")
        XCTAssertTrue(m.contains(.init(a: 2, b: 0)), "stroke to stroke: \(m)")
    }

    func testLeavingDrawsFirst() {
        let m = DeckMorph.match([g(nil, "circle", "Old")], [g(nil, "circle", "New")])
        XCTAssertEqual(m, [.init(a: 0, b: nil), .init(a: nil, b: 0)])
    }

    // MARK: pages

    func testPageFromShapes() {
        let p = page([shape("dot", "dot", "Dot"), shape(nil, "arrow"), shape("str", "circle", "String")])
        XCTAssertEqual(p.glyphs.map(\.kind), ["dot", "arrow", "circle"])
        XCTAssertEqual(p.glyphs.map(\.key), ["dot", nil, "str"])
        XCTAssertEqual(p.glyphs[2].pts.count, DeckMorph.ring, "a closed outline is a ring of points")
        XCTAssertEqual(p.glyphs[1].pts.count, DeckMorph.strand, "a stroke is a strand of points")
        XCTAssertTrue(p.glyphs[1].head)
        XCTAssertLessThan(p.bounds[0], p.glyphs[0].center[0])
    }

    func testMadeUpIdsAreNotKeys() {
        XCTAssertNil(DeckMorph.explicit("n12"))
        XCTAssertNil(DeckMorph.explicit("c3"))
        XCTAssertEqual(DeckMorph.explicit("string"), "string")
    }

    func testVennCrossFadesInstead() {
        XCTAssertNil(DeckMorph.page(ShapesModel.scene(head: [:], members: [shape(nil, "venn", nil, ["sets": .string("A|B")])])))
    }

    func testLoopsStartAtTheTopClockwise() {
        for kind in ["circle", "box", "pill", "blob"] {
            let l = DeckMorph.loop(DeckMorph.outline(kind, [3, 2], seed: 2))
            XCTAssertEqual(l.count, DeckMorph.ring, kind)
            XCTAssertLessThan(l[0][1], -0.8, "\(kind) starts at its top")
            XCTAssertGreaterThan(l[DeckMorph.ring / 8][0], l[0][0], "\(kind) runs clockwise on screen")
        }
    }

    // MARK: the tween

    func testEndsAreThePages() {
        let a = page([shape("s", "circle", "String", ["at": .string("3,3")])])
        let b = page([shape("s", "box", "String", ["at": .string("7,3")])])
        let start = DeckMorph.tween(a, b, t: 0, w: 300, h: 300)
        let end = DeckMorph.tween(a, b, t: 1, w: 300, h: 300)
        let camA = DeckMorph.camera(a, w: 300, h: 300), camB = DeckMorph.camera(b, w: 300, h: 300)
        XCTAssertEqual(start.count, 1, "one shape, matched, no leaving or arriving copy")
        for (p, q) in zip(start[0].pts, a.glyphs[0].pts.map(camA.at)) {
            XCTAssertEqual(p[0], q[0], accuracy: 1e-6); XCTAssertEqual(p[1], q[1], accuracy: 1e-6)
        }
        for (p, q) in zip(end[0].pts, b.glyphs[0].pts.map(camB.at)) {
            XCTAssertEqual(p[0], q[0], accuracy: 1e-6); XCTAssertEqual(p[1], q[1], accuracy: 1e-6)
        }
    }

    func testHalfwayIsBetween() {
        let a = page([shape("s", "circle", "A", ["at": .string("2,3")]), shape(nil, "box", "Pin", ["at": .string("8,3")])])
        let b = page([shape("s", "circle", "A", ["at": .string("8,3")]), shape(nil, "box", "Pin", ["at": .string("2,3")])])
        let s0 = DeckMorph.tween(a, b, t: 0, w: 400, h: 300), s1 = DeckMorph.tween(a, b, t: 1, w: 400, h: 300)
        let mid = DeckMorph.tween(a, b, t: 0.5, w: 400, h: 300)
        let x0 = s0[0].center[0], x1 = s1[0].center[0], xm = mid[0].center[0]
        XCTAssertLessThan(x0, xm)
        XCTAssertLessThan(xm, x1)
        XCTAssertEqual(xm, (x0 + x1) / 2, accuracy: 1, "the swap is symmetric, so halfway is the middle")
    }

    func testToneMixesAndLabelRetypes() {
        let a = page([shape("s", "circle", "Dot", ["tone": .string("accent")])])
        let b = page([shape("s", "circle", "String", ["tone": .string("mint")])])
        let early = DeckMorph.tween(a, b, t: 0.25, w: 300, h: 300)[0]
        let late = DeckMorph.tween(a, b, t: 0.9, w: 300, h: 300)[0]
        XCTAssertEqual(early.toneA, "accent"); XCTAssertEqual(early.toneB, "mint")
        XCTAssertGreaterThan(early.mix, 0); XCTAssertLessThan(early.mix, late.mix)
        XCTAssertTrue("Dot".hasPrefix(early.label) && !early.label.isEmpty && early.label != "Dot", "the old label backs out: \(early.label)")
        XCTAssertTrue("String".hasPrefix(late.label) && late.label.count >= 4, "the new label types in: \(late.label)")
    }

    func testArrivingDrawsOnAndLeavingDissolves() {
        let a = page([shape(nil, "circle", "Old")])
        let b = page([shape(nil, "box", "New")])
        let early = DeckMorph.tween(a, b, t: 0.1, w: 300, h: 300)
        let late = DeckMorph.tween(a, b, t: 0.95, w: 300, h: 300)
        XCTAssertGreaterThan(early[0].opacity, 0.5, "the old shape is still there early")
        XCTAssertEqual(early[1].trim, 0, "the new one has not started drawing")
        XCTAssertEqual(late[0].opacity, 0, "the old one is gone late")
        XCTAssertGreaterThan(late[1].trim, 0.95, "the new one is nearly drawn")
        XCTAssertEqual(late[1].label, "New")
    }

    func testLoopFoldsIntoAStroke() {
        let a = page([shape("s", "circle", nil, ["at": .string("5,3")])])
        let b = page([shape("s", "path", nil, ["pts": .array([.string("1,3"), .string("5,2"), .string("9,3")])])])
        let mid = DeckMorph.tween(a, b, t: 0.5, w: 300, h: 300)
        XCTAssertEqual(mid.count, 1)
        XCTAssertEqual(mid[0].pts.count, DeckMorph.ring, "a stroke runs out and back to meet a loop point for point")
    }

    func testStillCrossFades() {
        let a = page([shape("s", "circle", "A", ["at": .string("2,3")])])
        let b = page([shape("s", "circle", "A", ["at": .string("8,3")])])
        let mid = DeckMorph.tween(a, b, t: 0.5, w: 300, h: 300, still: true)
        XCTAssertEqual(mid.count, 2, "Reduce Motion: both pages, faded, nothing moves")
        XCTAssertEqual(mid[0].opacity, 0.5, accuracy: 1e-9)
    }

    func testEntranceFromNothing() {
        let b = page([shape(nil, "circle", "Hi")])
        XCTAssertEqual(DeckMorph.tween(nil, b, t: 0, w: 300, h: 300)[0].trim, 0)
        XCTAssertEqual(DeckMorph.tween(nil, b, t: 1, w: 300, h: 300)[0].trim, 1)
    }

    func testCameraZoomsASmallDrawing() {
        let p = page([shape(nil, "dot", nil, ["at": .string("5,3")]), shape(nil, "circle", "S", ["at": .string("6,3"), "size": .number(1)])])
        let cam = DeckMorph.camera(p, w: 390, h: 500)
        XCTAssertGreaterThan(cam.s, 390 / 10, "a drawing smaller than its canvas is framed bigger than the canvas would be")
        XCTAssertLessThanOrEqual(p.fs * cam.s, DeckMorph.maxFont + 1e-9, "labels never pass the cap")
    }

    func testAliveMovesALittle() {
        let b = page([shape(nil, "circle", "A")])
        let rest = DeckMorph.tween(nil, b, t: 1, w: 300, h: 300)
        let live = DeckMorph.alive(rest, time: 2.3, amp: 2)
        let d = zip(rest[0].pts, live[0].pts).map { hypot($0[0] - $1[0], $0[1] - $1[1]) }.max() ?? 0
        XCTAssertGreaterThan(d, 0.01)
        XCTAssertLessThan(d, 12)
    }

    func testResampleIsEven() {
        let r = DeckMorph.resample([[0, 0], [10, 0]], 11, closed: false)
        XCTAssertEqual(r.count, 11)
        XCTAssertEqual(r[5][0], 5, accuracy: 1e-9)
        XCTAssertEqual(r[10][0], 10, accuracy: 1e-9)
    }
}
