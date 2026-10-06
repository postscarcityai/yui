import XCTest
import YuiLines
@testable import Yui

/// Older stage replies fold into one chip in the chat (pick A, Oct 6).
@MainActor
final class StageFoldTests: XCTestCase {
    private let style: [String: String] = [:]

    private func reply(_ id: String, _ yl: String) -> ChatMessage {
        ChatMessage(id: id, text: "", fromUser: false, yl: YLScreen(yl))
    }

    private func timer(_ id: String) -> ChatMessage { reply(id, "timer \"Tea\" 180") }
    private func user(_ id: String) -> ChatMessage { ChatMessage(id: id, text: "hi", fromUser: true) }

    func testTwoStageRepliesDoNotFold() {
        let p = StageFold.plan([user("u1"), timer("a1"), user("u2"), timer("a2")], style: style)
        XCTAssertEqual(p, StageFold.Plan())
    }

    func testOlderStageRepliesFoldAndTheNewestStays() {
        let ms = [timer("a1"), user("u2"), timer("a2"), user("u3"), timer("a3")]
        let p = StageFold.plan(ms, style: style)
        XCTAssertEqual(p.folded, ["a1", "a2"])
        XCTAssertEqual(p.chipAt, "a1")
    }

    func testPlainWordsNeverFoldAndDoNotCount() {
        let ms = [timer("a1"), reply("w", "say \"Done.\""), timer("a2"), timer("a3"), timer("a4")]
        let p = StageFold.plan(ms, style: style)
        XCTAssertEqual(p.folded, ["a1", "a2", "a3"])
        XCTAssertFalse(p.folded.contains("w"))
    }

    func testAReplyWithWordsAroundItsPillStays() {
        let ms = [reply("a1", "say \"Ready.\"\ntimer \"Tea\" 180"), timer("a2"), timer("a3"), timer("a4")]
        XCTAssertEqual(StageFold.plan(ms, style: style).folded, ["a2", "a3"])
    }
}
