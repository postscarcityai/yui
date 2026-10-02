import Foundation
import Testing
@testable import YuiLines

// Draw anything on any screen (YUI-276). New `shape` kinds need nothing new in
// the parser (the kind is the first bare word, and any word goes), so these
// pin what does: a Venn's `sets` and `pairs` are always lists, `bend` and
// `rings` are numbers, `img` rides on the `shapes` head, and a plan takes a
// `shapes` as a page's picture, as a deck does.

private func props(_ line: String) -> [String: YLValue] { YuiLines.parse(line).first?.props ?? [:] }

@Test("shape venn: sets and pairs are lists, the label is the middle")
func vennLists() {
    let two = props("shape venn Yui sets=Chat|Drawing")
    #expect(two["kind"] == .string("venn"))
    #expect(two["label"] == .string("Yui"))
    #expect(two["sets"] == .array([.string("Chat"), .string("Drawing")]))
    let three = props("shape venn All sets=\"Design|Code|Words\" pairs=Mock|Sketch|Docs tone=mint")
    #expect(three["sets"] == .array([.string("Design"), .string("Code"), .string("Words")]))
    #expect(three["pairs"] == .array([.string("Mock"), .string("Sketch"), .string("Docs")]))
    // One set is still a list.
    #expect(props("shape venn sets=Ask")["sets"] == .array([.string("Ask")]))
}

@Test("shape region, doodle, contour: points stay as written, rings is a number")
func tracedKinds() {
    let region = props("shape region Field pts=1,1|6,0.8|8.6,2.4 +fill tone=butter")
    #expect(region["kind"] == .string("region"))
    #expect(region["pts"] == .array([.string("1,1"), .string("6,0.8"), .string("8.6,2.4")]))
    #expect(region["fill"] == .bool(true))
    let ring = props("shape doodle Here at=5,3 size=3,2")
    #expect(ring["kind"] == .string("doodle"))
    #expect(ring["at"] == .string("5,3"))
    #expect(ring["label"] == .string("Here"))
    let hill = props("shape contour Peak at=6,3 size=3.4,2.6 rings=5 +fill")
    #expect(hill["rings"] == .number(5))
}

@Test("shape arrow: bend is a number, either way")
func bentArrows() {
    #expect(props("shape arrow from=a to=b bend=0.3")["bend"] == .number(0.3))
    #expect(props("shape line from=b to=a bend=-0.25 +dash")["bend"] == .number(-0.25))
}

@Test("shapes: img= puts a picture under the drawing, its marks join it")
func marksOverAPicture() {
    let nodes = YuiLines.parse("shapes \"Fix this\" img=/demo/site_before_hero.jpg w=16 h=9\nshape doodle at=5,3 size=4,2 tone=butter\nshape arrow \"this one\" from=13,2 to=7,3 bend=0.3")
    #expect(nodes.map(\.preset) == ["shapes", "shape", "shape"])
    #expect(nodes[0].props?["img"] == .string("/demo/site_before_hero.jpg"))
    #expect(nodes[0].props?["title"] == .string("Fix this"))
    #expect(nodes.dropFirst().allSatisfy { $0.inGroup == nodes[0].id })
    #expect(nodes[2].props?["label"] == .string("this one"))
}

@Test("plan: shapes after a page joins the plan, its shapes join it, the next page goes back to the plan")
func shapesInAPlan() {
    let nodes = YuiLines.parse("plan P\npage One\nshapes Overlap\nshape venn Yui sets=Chat|Drawing\npage Two")
    #expect(nodes.map(\.preset) == ["plan", "page", "shapes", "shape", "page"])
    #expect(nodes[1].inGroup == nodes[0].id)
    #expect(nodes[2].inGroup == nodes[0].id)
    #expect(nodes[3].inGroup == nodes[2].id)
    #expect(nodes[4].inGroup == nodes[0].id)
}

@Test("marks: the same nodes when they stream a character at a time")
func marksStream() {
    let text = "plan P\npage One\nshapes Overlap img=/demo/a.jpg\nshape venn Yui sets=\"Chat|Drawing\"\nshape arrow bend=0.3\npage Two"
    var s = YLStreamParser()
    var streamed: [YLNode] = []
    for ch in text.unicodeScalars { streamed += s.push(String(ch)) }
    streamed += s.flush()
    #expect(streamed == YuiLines.parse(text))
}
