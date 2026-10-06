import XCTest
import YuiLines
@testable import Yui

/// Films on the phone (spec/MOTION.md section 0.5): the scene text, the parts joined, the reply that
/// carries only a later part drawing nothing.
@MainActor
final class MotionFilmsTests: XCTestCase {
    private let part1 = """
    motion "How a heart pumps blood" film=m7 part=1
    === scene hook 4 ===
    api.look('agent');
    api.say('Four rooms', 0.3, 3.5);
    === dive 6 ===
    api.shape('heart', api.w/2, 300, 160);
    api.say("Two sides", 0.3, 5);
    """
    private let part2 = """
    motion film=m7 part=2 +last
    === scene beat 5 ===
    api.say('Again and again', 0.2, 4);
    end
    """

    func testScenesReadHeadersWithOrWithoutTheWordScene() {
        let s = MotionFilmSource.scenes("=== scene a 4 ===\nx();\n=== b-c 99 ===\ny();\n=== broken ===\nz();")
        XCTAssertEqual(s.map(\.name), ["a", "b-c"])
        XCTAssertEqual(s.map(\.dur), [4, 20], "seconds are clamped to 0.5 to 20")
        XCTAssertEqual(s[0].code, "x();")
    }

    func testPartsJoinAndGapsHoldTheFilm() {
        let films = MotionFilms()
        films.receive(film: "m", title: "T", part: 1, last: false, source: "=== scene a 3 ===\nx();", live: true)
        films.receive(film: "m", title: "", part: 3, last: true, source: "=== scene c 3 ===\nz();", live: true)
        XCTAssertEqual(films.film("m")?.scenes.map(\.name), ["a"], "part 2 has not come: the film holds at what is known")
        XCTAssertEqual(films.film("m")?.complete, false)
        films.receive(film: "m", title: "", part: 2, last: false, source: "=== scene b 3 ===\ny();", live: true)
        XCTAssertEqual(films.film("m")?.scenes.map(\.name), ["a", "b", "c"])
        XCTAssertEqual(films.film("m")?.complete, true)
        XCTAssertEqual(films.film("m")?.title, "T")
    }

    func testTheSameRowTwiceChangesNothing() {
        let films = MotionFilms()
        for _ in 0..<2 { films.take(YuiLines.parse(part1), live: false) }
        XCTAssertEqual(films.film("m7")?.scenes.count, 2)
        XCTAssertEqual(films.film("m7")?.arrivedLive, false)
    }

    func testAFilmFromTwoRowsPlaysInOrderAndSaysItsWords() {
        let films = MotionFilms()
        films.take(YuiLines.parse(part1), live: true)
        XCTAssertEqual(films.film("m7")?.complete, false, "no last part yet")
        films.take(YuiLines.parse(part2), live: true)
        let f = films.film("m7")
        XCTAssertEqual(f?.scenes.map(\.name), ["hook", "dive", "beat"])
        XCTAssertEqual(f?.complete, true)
        XCTAssertEqual(f?.words, ["Four rooms", "Two sides", "Again and again"])
        XCTAssertEqual(f?.title, "How a heart pumps blood")
    }

    func testAFilmArrivingLiveOpensOnceAndHistoryNever() {
        let films = MotionFilms()
        films.take(YuiLines.parse(part1), live: true)
        XCTAssertTrue(films.shouldAutoOpen("m7"))
        XCTAssertFalse(films.shouldAutoOpen("m7"), "once")
        let old = MotionFilms()
        old.take(YuiLines.parse(part1), live: false)
        XCTAssertFalse(old.shouldAutoOpen("m7"))
    }

    func testALaterPartDrawsNothingAndTheFirstDoes() {
        let later = YLScreen(part2)
        XCTAssertTrue(later.isBlank, "a reply of only a later part is not a bubble")
        let first = YLScreen(part1)
        XCTAssertFalse(first.isBlank)
        XCTAssertEqual(first.top.first?.preset, "motion")
        let chunks = StageChunks.of(later, scope: "t")
        XCTAssertTrue(chunks.chunks.isEmpty, "and not a page on the stage")
        XCTAssertEqual(StageChunks.of(first, scope: "t").chunks.count, 1)
    }
}
