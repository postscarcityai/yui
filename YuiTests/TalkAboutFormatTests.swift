import XCTest
import YuiLines
@testable import Yui

/// Talk about this (YUI-69, spec yuigui spec/TALK-ABOUT.md): a message sent with
/// an item on the chip goes out as `[yui] attach section= id= rev=` then the words,
/// shows as the words with "About SOUL.md", and an applied proposal takes the chip off.
@MainActor
final class TalkAboutFormatTests: XCTestCase {
    let soul = TalkItem(section: .soul, itemID: "SOUL.md", rev: "b41c09", title: "SOUL.md", text: "# Scout")

    func testBodyAndMeta() throws {
        let body = TalkAbout.body("Calmer, please.", about: soul)
        XCTAssertEqual(body, "[yui] attach section=soul id=SOUL.md rev=b41c09\nCalmer, please.")
        let meta = TalkAbout.meta(nil, about: soul)
        XCTAssertEqual(TalkAbout.title(meta: meta), "SOUL.md")
        XCTAssertEqual(TalkAbout.words(body: body, meta: meta), "Calmer, please.")
        XCTAssertEqual(TalkAbout.words(body: body, meta: nil), body, "no about in meta: the body as it is")
    }

    func testTheBubbleShowsTheWordsAndTheTag() throws {
        let body = TalkAbout.body("Calmer, please.", about: soul)
        let m = ChatStore.userMessage(id: "u1", body: body, meta: TalkAbout.meta(nil, about: soul))
        XCTAssertEqual(m.text, "Calmer, please.")
        XCTAssertEqual(m.about, "SOUL.md")
        XCTAssertNil(m.fromScreen)
    }

    func testMemoryTitleIsItsFirstLineCut() {
        let item = ControlItem(id: "mem-1", text: "Knee felt tight after the 18 km on Sep 14. Keep the next two runs easy.\nMore.")
        let t = TalkItem.title(.memory, item)
        XCTAssertTrue(t.hasPrefix("Knee felt tight"))
        XCTAssertLessThanOrEqual(t.count, 40)
        XCTAssertEqual(TalkItem.title(.soul, item), "SOUL.md")
    }

    func testAnAppliedProposalTakesTheChipOff() throws {
        let store = ChatStore()
        store.about = soul
        let other = try YLValue.parseJSON(#"{"turn":["x"],"talk":{"applied":{"section":"memory","id":"mem-1"}}}"#)
        store.load([ThreadRow(id: "r1", sender: "agent", body: "done", kind: "text", meta: other, createdAt: "2026-09-26T10:00:00Z")])
        XCTAssertEqual(store.about, soul, "another item's receipt leaves the chip")
        let mine = try YLValue.parseJSON(#"{"turn":["y"],"talk":{"applied":{"section":"soul","id":"SOUL.md"}}}"#)
        store.load([ThreadRow(id: "r2", sender: "agent", body: "done", kind: "text", meta: mine, createdAt: "2026-09-26T10:01:00Z")])
        XCTAssertNil(store.about)
    }
}
