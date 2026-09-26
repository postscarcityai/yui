import XCTest
import YuiLines
@testable import Yui

/// Loop patterns (YUI-116, spec yuigui/spec/MUSIC.md section 2): the strings an
/// agent writes become a grid and come back the same; a drum take snaps to 16ths.
final class MusicPatternTests: XCTestCase {
    func testPatternRoundTrips() {
        let p = ["x...x.x.", "....x...", "", "xxxxxxxx"]
        let g = LoopPattern.grid(p, rows: 4, steps: 8)
        XCTAssertEqual(g[0], [true, false, false, false, true, false, true, false])
        XCTAssertEqual(g[2], Array(repeating: false, count: 8))
        XCTAssertEqual(LoopPattern.strings(g), p)
    }

    func testShortRowsPadAndLongRowsCut() {
        let g = LoopPattern.grid(["x.x", "x...x...x..."], rows: 3, steps: 4)
        XCTAssertEqual(LoopPattern.strings(g), ["x.x.", "x...", ""])
    }

    func testParsedLoopFeedsTheGrid() {
        let node = YuiLines.parse(#"loop 96 "Boom bap" p=x...x.x.|....x...|..x...x.|xxxxxxxx"#).first!
        let p = node.props?["p"]?.array?.compactMap(\.string) ?? []
        XCTAssertEqual(LoopPattern.strings(LoopPattern.grid(p, rows: 8, steps: 8)).prefix(4),
                       ["x...x.x.", "....x...", "..x...x.", "xxxxxxxx"])
    }

    func testTakeSnapsToSixteenths() {
        // 120 BPM: a 16th is 0.125 s. Slightly early and late hits land on the grid.
        let hits: [(pad: String, t: Double)] = [("kick", 0.01), ("hat", 0.24), ("kick", 0.99), ("hat", -0.02), ("snare", 5)]
        let take = LoopPattern.take(hits, pads: ["kick", "snare", "clap", "hat"], bpm: 120)
        XCTAssertEqual(take.rows, ["kick", "hat"])
        XCTAssertEqual(take.p[0], "x.......x" + String(repeating: ".", count: 23))
        XCTAssertEqual(take.p[1], "x.x" + String(repeating: ".", count: 29))
    }
}
