import XCTest
import YuiLines
@testable import Yui

/// An explainer deck compiles into one scene per page for the motion kit, on the phone (DeckFilm).
@MainActor
final class DeckFilmTests: XCTestCase {
    private let deck = """
    deck "String theory"
    page "Particles are not dots" body="Physics treats particles as points. String theory says they are tiny vibrating strings."
    shapes caption="Points become loops."
    shape dot "Point particle"
    shape arrow
    shape circle "String loop" +pulse
    page "Not proven yet" points="No string seen"|"The math works"
    sketch "Evidence" frame=bubble
    row "A string in a detector" +x
    row "The equations" +hi
    choose "Which is a string?" "A dot"|"A loop" answer="A loop"
    end
    """

    private func steps() -> (steps: [YLComponent], all: [YLComponent]) {
        let yl = YLScreen(deck)
        let head = yl.components.first { $0.preset == "deck" }!
        return (yl.components.steps(of: head), yl.components)
    }

    func testOneSceneAPage() {
        let (st, all) = steps()
        XCTAssertTrue(DeckFilm.canFilm(steps: st, all: all))
        let scenes = DeckFilm.scenes(steps: st, all: all)
        XCTAssertEqual(scenes.map(\.name), ["page-1", "page-2"])
        XCTAssertTrue(scenes.allSatisfy { $0.dur >= DeckFilm.leastScene && $0.dur <= DeckFilm.mostScene })
        // The first scene carries its title, its sentences and its drawing's parts, as data the kit reads.
        let one = scenes[0].code
        XCTAssertTrue(one.contains("\"title\":\"Particles are not dots\""))
        XCTAssertTrue(one.contains("Physics treats particles as points."))
        XCTAssertTrue(one.contains("String theory says they are tiny vibrating strings."))
        XCTAssertTrue(one.contains("\"kind\":\"dot\"") && one.contains("\"kind\":\"arrow\"") && one.contains("\"kind\":\"circle\""))
        XCTAssertTrue(one.contains("\"pulse\":true"))
        XCTAssertTrue(one.contains("api.kinetic(") && one.contains("api.say("))
        // The second speaks its points and the sketch's rows, and carries the rows to draw.
        let two = scenes[1].code
        XCTAssertTrue(two.contains("No string seen") && two.contains("The math works") && two.contains("A string in a detector"))
        XCTAssertTrue(two.contains("\"x\":true") && two.contains("\"hi\":true"))
    }

    func testBeatsFollowEachOtherAndSetTheLength() {
        let beats = DeckFilm.beats(["One short line.", "A second line with a good many more words in it than the first."])
        XCTAssertEqual(beats.count, 2)
        XCTAssertEqual(beats[0].from, DeckFilm.firstBeat)
        XCTAssertGreaterThan(beats[1].from, beats[0].to)
        XCTAssertGreaterThan(beats[1].to - beats[1].from, beats[0].to - beats[0].from)
        XCTAssertEqual(DeckFilm.duration(beats), min(DeckFilm.mostScene, max(DeckFilm.leastScene, beats[1].to + DeckFilm.tail)))
        XCTAssertEqual(DeckFilm.duration([]), DeckFilm.leastScene)
    }

    func testWordsAreTheFallback() {
        let (st, all) = steps()
        let words = DeckFilm.words(steps: st, all: all)
        XCTAssertEqual(words.first, "Particles are not dots")
        XCTAssertTrue(words.contains("The math works"))
    }

    func testAChartPageCannotFilm() {
        let yl = YLScreen("deck \"G\"\npage \"Up\" body=\"x\"\nchart line \"M\" x=a|b y=1|2\nend")
        let head = yl.components.first { $0.preset == "deck" }!
        XCTAssertFalse(DeckFilm.canFilm(steps: yl.components.steps(of: head), all: yl.components))
    }

    func testQuotesAndScriptCloseAreSafeInTheCode() {
        let yl = YLScreen("deck \"Q\"\npage \"He said \\\"hi\\\" </script>\" body=\"A line with a \\\"quote\\\".\"\nend")
        let head = yl.components.first { $0.preset == "deck" }!
        let code = DeckFilm.scenes(steps: yl.components.steps(of: head), all: yl.components)[0].code
        XCTAssertFalse(code.contains("</script>"))
        XCTAssertTrue(code.contains("\\\"hi\\\""))
    }
}
