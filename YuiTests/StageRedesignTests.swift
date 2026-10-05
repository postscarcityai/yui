import XCTest
import YuiLines
@testable import Yui

/// The stage redesign (Chris, Oct 2; feedback ACHcboRE, AOGmS_cF, APO8y7eU, AH_N-9fd): `Label: value`
/// lines read as one ledger with a mark each, a row that shows nothing leaves the working state up,
/// and a free drawing sizes itself from its own viewBox.
@MainActor
final class StageRedesignTests: XCTestCase {
    // MARK: The ledger

    func testLabelLinesBecomeLedgerRows() {
        let rows = StatusLedger.rows(ReadingBlock.parse("Push tap: fixed\nNew reply: plays itself\nShips: next build"))
        XCTAssertEqual(rows?.map(\.label), ["Push tap", "New reply", "Ships"])
        XCTAssertEqual(rows?.map(\.mark), [.good, .plain, .waiting])
    }

    func testOneLabelOrAnyProseIsNotALedger() {
        XCTAssertNil(StatusLedger.rows(ReadingBlock.parse("Push tap: fixed")))
        XCTAssertNil(StatusLedger.rows(ReadingBlock.parse("Push tap: fixed\nAnd then a sentence that is just words.")))
    }

    func testAMarkReadsTheValuesOwnWords() {
        XCTAssertEqual(StatusLedger.Mark.of("Declined"), .bad)
        XCTAssertEqual(StatusLedger.Mark.of("strong"), .good)
        XCTAssertEqual(StatusLedger.Mark.of("need help"), .waiting)
        XCTAssertEqual(StatusLedger.Mark.of("12 of 40"), .plain)
        // A word inside another word says nothing: "notable" is not "no".
        XCTAssertEqual(StatusLedger.Mark.of("notable"), .plain)
    }

    // MARK: Packing

    private func pages(_ yl: String) -> [[String?]] {
        StageChunks.pack(StageChunks.of(YLScreen(yl), scope: "r").chunks).map { $0.blocks.map(\.line) }
    }

    func testLabelLinesShareOnePageAsOneLedger() {
        XCTAssertEqual(pages("""
        say "Push tap: fixed"
        say "New reply: plays itself"
        say "Ships: next build"
        """), [["Push tap: fixed\nNew reply: plays itself\nShips: next build"]])
    }

    func testALedgerNeverRidesUnderADrawing() {
        let p = pages("""
        say "Push tap fixed."
        sketch
        row "Tap opens the reply" +hi
        say "Push tap: fixed"
        say "Ships: next build"
        """)
        XCTAssertEqual(p.count, 2)
        XCTAssertEqual(p[1], ["Push tap: fixed\nShips: next build"])
    }

    func testProseAfterALedgerStartsItsOwnPage() {
        let p = pages("""
        say "Site: good"
        say "SEO: strong"
        say "Three builds shipped this week."
        """)
        XCTAssertEqual(p, [["Site: good\nSEO: strong"], ["Three builds shipped this week."]])
    }

    // MARK: The working state

    func testOnlySomethingToReadEndsTheWait() {
        let words = ChatMessage(id: "a", text: "Done.", fromUser: false)
        XCTAssertTrue(ChatStore.answersTurn([words]))
        // A turn that came back with nothing at all still ends.
        XCTAssertTrue(ChatStore.answersTurn([]))
        // Lines for a side screen only: nothing to read on the stage, the agent is still on it.
        let side = ChatMessage(id: "b", text: "", fromUser: false, yl: YLScreen(">2 timer 60"))
        XCTAssertFalse(ChatStore.answersTurn([side]))
        let here = ChatMessage(id: "c", text: "", fromUser: false, yl: YLScreen("say Hello."))
        XCTAssertTrue(ChatStore.answersTurn([side, here]))
        XCTAssertFalse(ChatStore.answersTurn([ChatMessage(id: "d", text: "  \n", fromUser: false)]))
    }

    // MARK: Free drawing

    func testADrawingTakesItsShapeFromItsViewBox() {
        XCTAssertEqual(DrawPage.ratio(nil, source: "<svg viewBox=\"0 0 360 240\"></svg>"), 1.5, accuracy: 0.001)
        XCTAssertEqual(DrawPage.ratio("16:9", source: "<svg viewBox=\"0 0 10 10\"></svg>"), 16.0 / 9.0, accuracy: 0.001)
        XCTAssertEqual(DrawPage.ratio(nil, source: "<canvas></canvas>"), 4.0 / 3.0, accuracy: 0.001)
        // A wrong number never makes a sliver.
        XCTAssertEqual(DrawPage.ratio("100:1", source: ""), 4, accuracy: 0.001)
        XCTAssertEqual(DrawPage.ratio(nil, source: "<svg viewBox='0 0 10 400'></svg>"), 0.7, accuracy: 0.001)
    }

    func testADrawingsPageLoadsNothingFromOutside() {
        let p = YuiTheme.yui.palette(for: .dark)
        let html = DrawPage.html("<svg viewBox=\"0 0 4 3\"><circle class=\"draw\" cx=\"2\" cy=\"1\" r=\"1\"/></svg>",
                                 palette: p, dark: true, good: "#3fbf8a", bad: "#ff7a6b", still: false)
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertFalse(DrawPage.policy.contains("http"))
        XCTAssertFalse(DrawPage.policy.contains("connect-src"))
        XCTAssertTrue(html.contains("--accent:\(p.accent)"))
    }

    /// Marks in free SVG (YUI-276): `rough` draws a part by hand, `wash` tints a fill so overlaps read darker.
    func testAFreeDrawingCanLookHandDrawn() {
        let html = DrawPage.html("<svg viewBox=\"0 0 360 240\"><path class=\"draw rough accent\" d=\"M10 10 L300 200\"/></svg>",
                                 palette: YuiTheme.yui.palette(for: .light), dark: false, good: "#13875a", bad: "#c93c2c", still: false)
        XCTAssertTrue(html.contains("<filter id=\"yui-rough\""))
        XCTAssertTrue(html.contains(".rough{filter:url(#yui-rough)}"))
        XCTAssertTrue(html.contains(".wash{fill-opacity:.18}"))
        // The filter's own box never takes the drawing's place.
        XCTAssertTrue(html.contains("body>svg:not(.yui-defs)"))
    }

    func testADrawParsesIntoOneComponentWithItsMarkup() {
        let yl = YLScreen("say Tap a push.\ndraw \"Push tap\"\n<svg viewBox=\"0 0 4 3\">\n<circle cx=\"2\" cy=\"1\" r=\"1\"/>\n</svg>\nend")
        let draw = yl.components.first { $0.preset == "draw" }
        XCTAssertEqual(draw?.string("title"), "Push tap")
        XCTAssertEqual(draw?.string("source")?.contains("<circle"), true)
        // The line before it takes it as its picture, as any drawing.
        let chunks = StageChunks.of(yl, scope: "r").chunks
        XCTAssertEqual(chunks.map { [$0.line, $0.pic?.preset] }, [["Tap a push.", "draw"]])
    }
}
