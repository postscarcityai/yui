import XCTest
@testable import Yui

/// Markdown in agent bubbles (YUI-76): a slash command's answer reads without
/// raw ** and backticks, each element draws, a yui fence stays word for word,
/// and anything malformed falls back to the words as written.
final class BubbleMarkdownTests: XCTestCase {
    private func runs(_ text: String) -> [(String, InlinePresentationIntent?, URL?)] {
        let a = BubbleMarkdown.attributed(text)
        return a.runs.map { (String(a[$0.range].characters), $0.inlinePresentationIntent, $0.link) }
    }

    private func intent(of word: String, in text: String) -> InlinePresentationIntent? {
        runs(text).first { $0.0 == word }?.1
    }

    func testPlainTextIsUntouched() {
        let s = "It went well. Every test is green, 1.0 wins; see src/a2a.ts."
        XCTAssertEqual(BubbleMarkdown.plain(s), s)
        XCTAssertEqual(runs(s).count, 1)
        XCTAssertEqual(BubbleMarkdown.plain("Line one\n\nLine two"), "Line one\n\nLine two")
    }

    func testStatusAnswerLosesItsMarks() {
        let plain = BubbleMarkdown.plain(ChatView.statusAnswer)
        XCTAssertFalse(plain.contains("**"))
        XCTAssertFalse(plain.contains("`"))
        XCTAssertTrue(plain.contains("Model: claude-opus-5-5 (custom)"))
        XCTAssertEqual(intent(of: "Model:", in: ChatView.statusAnswer), .stronglyEmphasized)
        XCTAssertEqual(intent(of: "claude-opus-5-5", in: ChatView.statusAnswer), .code)
    }

    func testEmphasis() {
        XCTAssertEqual(intent(of: "bold", in: "a **bold** b"), .stronglyEmphasized)
        XCTAssertEqual(intent(of: "it", in: "a *it* b"), .emphasized)
        XCTAssertEqual(intent(of: "it", in: "a _it_ b"), .emphasized)
        XCTAssertEqual(intent(of: "gone", in: "a ~~gone~~ b"), .strikethrough)
        XCTAssertEqual(BubbleMarkdown.plain("snake_case_name stays"), "snake_case_name stays")
    }

    func testCodeBlockKeepsItsLines() {
        let s = "Run:\n```swift\nlet a = 1\n  **not bold**\n```\nDone"
        XCTAssertEqual(BubbleMarkdown.plain(s), "Run:\nlet a = 1\n  **not bold**\nDone")
        XCTAssertEqual(intent(of: "let a = 1\n  **not bold**", in: s), .code)
    }

    func testLists() {
        XCTAssertEqual(BubbleMarkdown.plain("- one\n* two\n+ **three**"), "•  one\n•  two\n•  three")
        XCTAssertEqual(BubbleMarkdown.plain("1. one\n2) two"), "1.  one\n2.  two")
        XCTAssertEqual(BubbleMarkdown.plain("- top\n  - nested"), "•  top\n   •  nested")
        XCTAssertEqual(intent(of: "three", in: "- **three**"), .stronglyEmphasized)
    }

    func testHeadingReadsBold() {
        XCTAssertEqual(BubbleMarkdown.plain("## Build 92"), "Build 92")
        XCTAssertEqual(intent(of: "Build 92", in: "## Build 92"), .stronglyEmphasized)
        XCTAssertEqual(BubbleMarkdown.plain("#hashtag stays"), "#hashtag stays")
    }

    func testOnlyHttpsLinksTap() {
        let r = runs("[site](https://www.yuigui.com), [old](http://a.b), [bad](javascript:alert(1))")
        XCTAssertEqual(r.first { $0.0 == "site" }?.2, URL(string: "https://www.yuigui.com"))
        XCTAssertNil(r.first { $0.0 == "old" }?.2)
        XCTAssertNil(r.first { $0.0 == "bad" }?.2)
        XCTAssertEqual(BubbleMarkdown.plain("[site](https://x.com)"), "site")
    }

    func testYuiFenceIsLeftAlone() {
        let s = "Pick one.\n```yui\nchoose \"Split?\" Push|Pull|**Legs**\n```"
        XCTAssertEqual(BubbleMarkdown.plain(s), s)
        XCTAssertTrue(runs(s).allSatisfy { $0.1 == nil })
    }

    func testMalformedFallsBackToPlain() {
        XCTAssertEqual(BubbleMarkdown.plain("**unclosed bold"), "**unclosed bold")
        XCTAssertEqual(BubbleMarkdown.plain("a `tick and *star"), "a `tick and *star")
        XCTAssertEqual(BubbleMarkdown.plain("```\nnever closed"), "```\nnever closed")
        XCTAssertEqual(BubbleMarkdown.plain("[half](link"), "[half](link")
        XCTAssertEqual(BubbleMarkdown.plain("pair <code> --card <url>"), "pair <code> --card <url>")
    }

    func testCopyAndQuoteTakeThePlainWords() {
        let agent = ChatMessage(text: "**Model:** `x`", fromUser: false)
        XCTAssertEqual(agent.words, "Model: x")
        XCTAssertEqual(ReplyQuote(agent)?.quote, "Model: x")
        let person = ChatMessage(text: "**keep** mine", fromUser: true)
        XCTAssertEqual(person.words, "**keep** mine")
    }

    func testLongMarkdownFoldsOnItsWords() {
        let long = (1...70).map { "**w\($0)**" }.joined(separator: " ")
        XCTAssertTrue(LongText.folds(BubbleMarkdown.plain(long)))
        XCTAssertFalse(LongText.excerpt(BubbleMarkdown.plain(long)).contains("**"))
    }
}
