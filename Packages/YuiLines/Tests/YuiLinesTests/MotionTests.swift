import Foundation
import Testing
@testable import YuiLines

// `motion`: the head is an add, the scenes under it are the film's own (never read as YL), and `end` gives
// one patch with them as `source` (spec/MOTION.md section 0.5).

let heartFilm = """
motion "How a heart pumps blood" film=m7 part=1
=== scene hook 4 ===
api.look('agent');
api.shape('heart', api.w/2, 300, 160, {k: api.seg(t, 0, 1.5)});
timer 60
=== scene dive 6 ===
api.say('Four rooms', 0.3, 5);
end
say Done.
"""

@Test("motion: an add, then one patch with the scenes")
func motionBlock() {
    let nodes = YuiLines.parse(heartFilm)
    #expect(nodes.map(\.op) == [.add, .patch, .add])
    #expect(nodes[0].preset == "motion")
    #expect(nodes[0].props?["title"]?.string == "How a heart pumps blood")
    #expect(nodes[0].props?["film"]?.string == "m7")
    #expect(nodes[1].target == nodes[0].id)
    let source = nodes[1].props?["source"]?.string ?? ""
    #expect(source.hasPrefix("=== scene hook 4 ==="))
    #expect(source.hasSuffix("api.say('Four rooms', 0.3, 5);"))
    // A line that would be a preset is still the film's.
    #expect(source.contains("timer 60"))
}

@Test("motion: the same nodes when it streams a character at a time")
func motionStreams() {
    var s = YLStreamParser()
    var streamed: [YLNode] = []
    for ch in heartFilm.unicodeScalars { streamed += s.push(String(ch)) }
    streamed += s.flush()
    #expect(streamed == YuiLines.parse(heartFilm))
}

@Test("motion: left open at the end of the reply, it still gives its patch")
func motionLeftOpen() {
    let nodes = YuiLines.parse("motion film=a part=2 +last\n=== scene b 5 ===\nc.fillRect(0,0,9,9);")
    #expect(nodes.map(\.op) == [.add, .patch])
    #expect(nodes[0].props?["part"]?.number == 2)
    #expect(nodes[1].props?["source"]?.string?.contains("fillRect") == true)
}

@Test("motion: no scene header after the head, the next line is YL")
func motionWithoutScenes() {
    let nodes = YuiLines.parse("motion \"Empty\"\ntimer 60")
    #expect(nodes.map(\.preset) == ["motion", "timer"])
    #expect(nodes.allSatisfy { $0.op == .add })
}

@Test("motion: a runaway film is cut by characters, and its end still closes it")
func motionIsCapped() {
    let big = (["motion", "=== scene a 5 ==="] + Array(repeating: String(repeating: "x", count: 1000), count: 300) + ["end", "timer 60"]).joined(separator: "\n")
    let nodes = YuiLines.parse(big)
    #expect(nodes.map(\.op) == [.add, .patch, .add])
    #expect((nodes[1].props?["source"]?.string ?? "").count <= YLMotionReader.mostChars)
}
