import XCTest
import YuiLines
@testable import Yui

/// Long plain answers (YUI-79): past 60 words an agent's bubble folds to its
/// first sentences, and the whole text reads as a deck of short pages.
@MainActor
final class LongTextTests: XCTestCase {
    static let report = ChatView.longReport

    func testOnlyLongTextFolds() {
        let sixty = Array(repeating: "word", count: LongText.foldWords).joined(separator: " ")
        XCTAssertFalse(LongText.folds(sixty), "exactly the threshold stays a bubble")
        XCTAssertTrue(LongText.folds(sixty + " more"))
        XCTAssertFalse(LongText.folds("It went well. Every test is green."))
        XCTAssertTrue(LongText.folds(Self.report))
        XCTAssertEqual(LongText.wordCount("  one\ttwo\n\nthree  "), 3)
    }

    func testSentencesKeepVersionsFilesAndAbbreviations() {
        XCTAssertEqual(LongText.sentences("A2A 1.0 wins. Run src/a2a.ts now! Why? Ask e.g. Luna. Done"),
                       ["A2A 1.0 wins.", "Run src/a2a.ts now!", "Why?", "Ask e.g. Luna.", "Done"])
        XCTAssertEqual(LongText.sentences("One line\nTwo line."), ["One line", "Two line."])
    }

    func testExcerptIsTheFirstWholeSentences() {
        let e = LongText.excerpt(Self.report)
        XCTAssertEqual(e, "A2A bridge: add any A2A agent to Yui by its Agent Card. node adapters/a2a/yui-a2a.ts pair <code> "
                       + "--card <url>, then run; add --card <url> puts more agents on the same machine…")
        XCTAssertLessThanOrEqual(LongText.wordCount(e), LongText.excerptWords)
        XCTAssertFalse(e.contains("No app binary change"))
    }

    func testExcerptCutsAHugeFirstSentenceAtAWord() {
        let words = (1...100).map { "w\($0)" }.joined(separator: " ") + "."
        let e = LongText.excerpt(words)
        XCTAssertTrue(e.hasPrefix("w1 w2 w3"))
        XCTAssertTrue(e.hasSuffix("w40…"), e)
    }

    func testTitleIsNeverEmpty() {
        XCTAssertEqual(LongText.title(Self.report), "A2A bridge")
        XCTAssertEqual(LongText.title("The deploy is done. More later."), "The deploy is done")
        XCTAssertEqual(LongText.title("   "), "Message")
        XCTAssertEqual(LongText.title((1...20).map { "w\($0)" }.joined(separator: " ")), "w1 w2 w3 w4 w5 w6 w7 w8…")
    }

    func testReportPagesAreShortAndLoseNothing() {
        let pages = LongText.pages(Self.report)
        XCTAssertGreaterThanOrEqual(pages.count, 4)
        XCTAssertLessThanOrEqual(pages.count, 7)
        for p in pages {
            // A single sentence of up to `hugeWords` may stand alone; nothing is a wall.
            XCTAssertLessThanOrEqual(LongText.wordCount(p), LongText.hugeWords, p)
        }
        XCTAssertEqual(pages.joined(separator: " ").split(whereSeparator: \.isWhitespace),
                       Self.report.split(whereSeparator: \.isWhitespace), "every word, in order")
        XCTAssertTrue(pages[0].hasPrefix("A2A bridge: add any A2A agent"))
        XCTAssertTrue(pages.last!.hasSuffix("No app binary change (INT-18)"))
        // Whole sentences: page 2 starts where a sentence starts.
        XCTAssertTrue(pages[1].hasPrefix("Runtime-neutral TypeScript client"))
    }

    func testParagraphsBreakFirstAndShortOnesShare() {
        let a = Array(repeating: "Alpha is here.", count: 10).joined(separator: " ")  // 30 words
        let b = Array(repeating: "Bravo is here.", count: 10).joined(separator: " ")
        let c = Array(repeating: "Charlie is here.", count: 20).joined(separator: " ")  // 60 words
        let pages = LongText.pages([a, b, c].joined(separator: "\n\n"))
        XCTAssertEqual(pages, [a + "\n\n" + b, c], "two short paragraphs share a page; the next one starts its own")
    }

    func testALongParagraphSplitsEvenlyBetweenSentences() {
        let text = Array(repeating: "This sentence has exactly six words.", count: 25).joined(separator: " ")  // 150 words
        let pages = LongText.pages(text)
        XCTAssertEqual(pages.count, 3)
        for p in pages {
            XCTAssertTrue((LongText.pageWords).contains(LongText.wordCount(p)), "\(LongText.wordCount(p)) words")
            XCTAssertTrue(p.hasSuffix("words."), "a page ends at a sentence")
        }
    }

    func testAnEnormousSentenceSplitsAtWords() {
        let text = (1...200).map { "w\($0)" }.joined(separator: " ")
        let pages = LongText.pages(text)
        XCTAssertEqual(pages.count, 3)
        for p in pages { XCTAssertLessThanOrEqual(LongText.wordCount(p), LongText.pageWords.upperBound) }
        XCTAssertEqual(pages.joined(separator: " "), text)
    }

    func testTheDeckIsADeckOfPages() throws {
        let yl = LongText.deck(Self.report)
        let deck = try XCTUnwrap(yl.top.first)
        XCTAssertEqual(yl.top.count, 1, "the pages ride inside the deck")
        XCTAssertEqual(deck.preset, "deck")
        XCTAssertEqual(deck.string("title"), "A2A bridge")
        let pages = yl.components.members(of: deck)
        XCTAssertEqual(pages.map(\.preset), Array(repeating: "page", count: LongText.pages(Self.report).count))
        XCTAssertEqual(pages.first?.string("body"), LongText.pages(Self.report).first)
        XCTAssertFalse(yl.staged([:]).isEmpty, "it opens on the stage")
        XCTAssertFalse(yl.staged(["screen": "chat"]).isEmpty, "even for an agent that keeps things in the chat")
    }

    func testReadAsPagesOpensTheDeckOnTheStage() throws {
        let m = ChatMessage(text: Self.report, fromUser: false)
        let store = ChatStore(messages: [m])
        store.readAsPages(m)
        XCTAssertTrue(store.stageOpen)
        let staged = try XCTUnwrap(store.stageMessage)
        XCTAssertEqual(staged.yl?.top.first?.preset, "deck")
        XCTAssertEqual(store.messages.count, 1, "the thread keeps the one message")
        store.closeStage()
        XCTAssertFalse(store.stageOpen)
    }
}
