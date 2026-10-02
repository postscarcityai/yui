import Foundation
import Testing
@testable import YuiLines

// `draw`: the head is an add, the markup under it is the drawing's own (never
// read as YL), and `end` gives one patch with it as `source`.

let pushTap = """
draw "Push tap" caption="Tap the banner."
<svg viewBox="0 0 360 250">
  <rect class="draw" x="30" y="14" width="120" height="222" rx="20"/>
  <text x="50" y="43">timer 60</text>
</svg>
end
say Done.
"""

@Test("draw: an add, then one patch with the markup")
func drawBlock() {
    let nodes = YuiLines.parse(pushTap)
    #expect(nodes.map(\.op) == [.add, .patch, .add])
    #expect(nodes[0].preset == "draw")
    #expect(nodes[0].props?["title"]?.string == "Push tap")
    #expect(nodes[0].props?["caption"]?.string == "Tap the banner.")
    #expect(nodes[1].target == nodes[0].id)
    let source = nodes[1].props?["source"]?.string ?? ""
    #expect(source.hasPrefix("<svg viewBox=\"0 0 360 250\">"))
    #expect(source.hasSuffix("</svg>"))
    // A line that would be a preset is still the drawing's.
    #expect(source.contains("timer 60"))
    #expect(nodes[2].preset == "say" || nodes[2].props?["text"]?.string == "Done.")
}

@Test("draw: the same nodes when it streams a character at a time")
func drawStreams() {
    var s = YLStreamParser()
    var streamed: [YLNode] = []
    for ch in pushTap.unicodeScalars { streamed += s.push(String(ch)) }
    streamed += s.flush()
    #expect(streamed == YuiLines.parse(pushTap))
}

@Test("draw: left open at the end of the reply, it still gives its patch")
func drawLeftOpen() {
    let nodes = YuiLines.parse("draw\n<svg viewBox=\"0 0 10 10\"><circle cx=\"5\" cy=\"5\" r=\"4\"/></svg>")
    #expect(nodes.map(\.op) == [.add, .patch])
    #expect(nodes[1].props?["source"]?.string?.contains("<circle") == true)
}

@Test("draw: no markup after the head, the next line is YL")
func drawWithoutMarkup() {
    let nodes = YuiLines.parse("draw \"Empty\"\ntimer 60")
    #expect(nodes.map(\.preset) == ["draw", "timer"])
    #expect(nodes.allSatisfy { $0.op == .add })
}

@Test("draw: a page's picture inside a deck")
func drawInDeck() {
    let nodes = YuiLines.parse("deck \"Lesson\"\npage \"One\"\ndraw\n<svg viewBox=\"0 0 4 3\"></svg>\nend\npage \"Two\"")
    let deck = nodes[0].id
    #expect(nodes.filter { $0.op == .add }.map(\.preset) == ["deck", "page", "draw", "page"])
    #expect(nodes.filter { $0.op == .add }.dropFirst().allSatisfy { $0.inGroup == deck })
}

@Test("draw: a runaway drawing is cut, and its end still closes it")
func drawIsCapped() {
    let long = (["draw", "<svg>"] + Array(repeating: "<path d=\"M0 0\"/>", count: 2000) + ["end", "timer 60"]).joined(separator: "\n")
    let nodes = YuiLines.parse(long)
    #expect(nodes.map(\.op) == [.add, .patch, .add])
    #expect((nodes[1].props?["source"]?.string ?? "").split(separator: "\n").count == YLDrawReader.mostLines)
    #expect(nodes[2].preset == "timer")
}
