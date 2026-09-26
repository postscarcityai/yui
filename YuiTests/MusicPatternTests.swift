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

/// The keyboard's hit test (YUI-116 step 3): black keys win where they sit on
/// the white ones, and every finger position lands on exactly one key.
final class KeyboardLayoutTests: XCTestCase {
    let size = CGSize(width: 350, height: 200)

    func testWhiteKeysAcrossTheBottom() {
        let w = size.width / 10
        let bottom = (0..<10).map { KeyboardLayout.semitone(at: CGPoint(x: (Double($0) + 0.5) * w, y: 190), in: size) }
        XCTAssertEqual(bottom, [0, 2, 4, 5, 7, 9, 11, 12, 14, 16])
    }

    func testBlackKeysOnTop() {
        let w = size.width / 10
        // Each black key straddles the line left of its white key.
        let top = [1, 2, 4, 5, 6, 8, 9].map { KeyboardLayout.semitone(at: CGPoint(x: Double($0) * w, y: 40), in: size) }
        XCTAssertEqual(top, [1, 3, 6, 8, 10, 13, 15])
        // Between E and F there is no black key.
        XCTAssertEqual(KeyboardLayout.semitone(at: CGPoint(x: 3 * w, y: 40), in: size), 5)
    }

    func testOffTheKeysIsNothing() {
        XCTAssertNil(KeyboardLayout.semitone(at: CGPoint(x: -1, y: 10), in: size))
        XCTAssertNil(KeyboardLayout.semitone(at: CGPoint(x: 10, y: 201), in: size))
        XCTAssertNil(KeyboardLayout.semitone(at: CGPoint(x: 10, y: 10), in: .zero))
    }

    /// A glide from C to the E above crosses every key in order, once each.
    func testAGlideCrossesEveryKeyInOrder() {
        var seen: [Int] = []
        for x in stride(from: 0.0, to: size.width, by: 1) {
            if let s = KeyboardLayout.semitone(at: CGPoint(x: x, y: 190), in: size), seen.last != s { seen.append(s) }
        }
        XCTAssertEqual(seen, KeyboardLayout.white)
    }
}
