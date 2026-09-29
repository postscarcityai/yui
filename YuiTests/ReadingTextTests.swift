import XCTest
@testable import Yui

/// A real body style (YUI-196): big type is for one short line, longer words read
/// as body, and markdown is drawn, never shown as ** or #.
final class ReadingTextTests: XCTestCase {
    func testOneShortLineIsAHeadline() {
        XCTAssertEqual(ReadingType.role("Yes. Build 160, the newest."), .headline)
        XCTAssertEqual(ReadingType.role("**Two** things"), .headline)
    }

    func testALongSentenceReadsAsBody() {
        let t = "Chicken and rice, about 384 kcal. Sure on the chicken and rice. Less sure on oil used to cook."
        XCTAssertEqual(ReadingType.role(t), .body)
        XCTAssertEqual(ReadingType.role("The publish pipeline still makes audio, and nothing on the board switches it to video."), .body)
    }

    func testListsHeadingsAndLabelLinesAreBody() {
        XCTAssertEqual(ReadingType.role("- one\n- two"), .body)
        XCTAssertEqual(ReadingType.role("## Plan"), .body)
        XCTAssertEqual(ReadingType.role("Publishing pipeline: still makes audio"), .body)
    }

    func testMarkdownIsDrawnNeverShownRaw() {
        let md = "# Video in posts\n\n**Publishing pipeline:** still makes audio\nTechnically possible ✅\nVideo in every post ❌\n\n- first\n- second\n1. one\n2. two\nSome `code` and *emphasis* and a [link](https://yuigui.com)."
        let plain = ReadingBlock.parse(md).map(Self.words).joined(separator: "\n")
        XCTAssertFalse(plain.contains("**"))
        XCTAssertFalse(plain.contains("#"))
        XCTAssertFalse(plain.contains("`"))
        XCTAssertTrue(plain.contains("Publishing pipeline: still makes audio"))
        XCTAssertTrue(plain.contains("✅"))
    }

    func testTheLabelIsSplitFromItsValue() {
        let blocks = ReadingBlock.parse("**Publishing pipeline:** still makes audio\nVideo in every post: no")
        guard case .label(let l1, let v1) = blocks[0], case .label(let l2, _) = blocks[1] else { return XCTFail("\(blocks)") }
        XCTAssertEqual(l1, "Publishing pipeline")
        XCTAssertEqual(String(v1.characters), "still makes audio")
        XCTAssertEqual(l2, "Video in every post")
    }

    func testALinkOrATimeIsNotALabel() {
        guard case .paragraph = ReadingBlock.parse("https://yuigui.com/board")[0] else { return XCTFail() }
        guard case .paragraph = ReadingBlock.parse("Meet at 8:00 AM tomorrow")[0] else { return XCTFail() }
    }

    func testAloneAHyphenLineIsAPlainLine() {
        let blocks = ReadingBlock.parse("- **From now on:** every post ships with a video.")
        guard case .label(let l, let v) = blocks[0] else { return XCTFail("\(blocks)") }
        XCTAssertEqual(l, "From now on")
        XCTAssertEqual(String(v.characters), "every post ships with a video.")
        XCTAssertEqual(BubbleMarkdown.plain("- just one"), "just one")
        XCTAssertEqual(BubbleMarkdown.plain("- one\n- two"), "•  one\n•  two")
    }

    func testAWholeThoughtStaysOnOnePage() {
        let t = "Future posts ship with a video like the Marketing Hours one. If a video fails to build the post gets audio. A card is filed to add the video later."
        XCTAssertEqual(StageChunks.text(t), [t])
    }

    func testAMarkdownParagraphKeepsItsLines() {
        let t = "**Publishing:** still audio\nTechnically possible ✅\n- video ❌"
        XCTAssertEqual(StageChunks.text(t), [t])
    }

    func testTheRichFixtureParses() {
        let md = "## Video in every post\n**Publishing pipeline:** still makes audio\n**Technically possible:** yes ✅\n**Video in every post:** not yet ❌\n- Build the video\n- Post it with `publish`"
        let blocks = ReadingBlock.parse(md)
        XCTAssertEqual(blocks.count, 6, "\(blocks)")
        XCTAssertEqual(StageChunks.text(md), [md])
        XCTAssertEqual(ReadingType.role(md), .body)
    }

    private static func words(_ b: ReadingBlock) -> String {
        switch b {
        case .heading(let a, _), .paragraph(let a), .bullet(let a, _): String(a.characters)
        case .number(let n, let a, _): n + ". " + String(a.characters)
        case .label(let l, let a): l + ": " + String(a.characters)
        case .code(let s): s
        case .gap: ""
        }
    }
}
