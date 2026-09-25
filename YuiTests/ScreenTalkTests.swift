import XCTest
import YuiLines
@testable import Yui

/// Chat with a screen (YUI-62, spec YL.md section 5 Pages and section 7): `>2 talk`
/// keeps the composer on page 2 across replies until `talk off` or `>2 clear`, and
/// what the person types there goes out as `[yui] screen=2` then the words.
@MainActor
final class ScreenTalkTests: XCTestCase {
    static func agent(_ id: String, _ yl: String, at: String) -> ThreadRow {
        ThreadRow(id: id, sender: "agent", body: "```yui\n\(yl)\n```", kind: "text", meta: nil, createdAt: at)
    }

    func testTalkKeepsTheComposerOnThatPageOnly() {
        let store = ChatStore()
        store.load([Self.agent("r1", """
        >2 card "Week one" body="Three runs"
        >2 talk
        >3 list Notes A|B
        """, at: "2026-09-25T10:00:00Z")])
        XCTAssertEqual(store.screens, [1, 2, 3])
        XCTAssertEqual(store.talking, [2])
        XCTAssertTrue(store.talks(on: 1), "the chat always has its composer")
        XCTAssertTrue(store.talks(on: 2))
        XCTAssertFalse(store.talks(on: 3), "a page is for reading unless the agent says talk")
    }

    func testTalkLastsAcrossRepliesUntilOffOrClear() {
        let first = Self.agent("r1", ">2 card Plan\n>2 talk\n>3 say Notes\n>3 talk", at: "2026-09-25T10:00:00Z")
        let store = ChatStore()
        store.load([first, Self.agent("r2", "say Still here.", at: "2026-09-25T10:01:00Z")])
        XCTAssertEqual(store.talking, [2, 3], "a later reply keeps what an earlier one said")

        let off = ChatStore()
        off.load([first, Self.agent("r2", ">2 talk off", at: "2026-09-25T10:01:00Z")])
        XCTAssertEqual(off.talking, [3])

        let cleared = ChatStore()
        cleared.load([first, Self.agent("r2", ">3 clear", at: "2026-09-25T10:01:00Z")])
        XCTAssertEqual(cleared.talking, [2], "clear takes the page and its composer")
        XCTAssertEqual(cleared.screens, [1, 2])

        let again = ChatStore()
        again.load([first, Self.agent("r2", ">3 clear", at: "2026-09-25T10:01:00Z"),
                    Self.agent("r3", ">3 say Back\n>3 talk", at: "2026-09-25T10:02:00Z")])
        XCTAssertEqual(again.talking, [2, 3], "a clear in an earlier reply does not undo a later talk")
    }

    func testOnlyPagesTalk() {
        let store = ChatStore()
        store.load([Self.agent("r1", "talk\n>full talk\n>13 say Chat\n>13 talk", at: "2026-09-25T10:00:00Z")])
        XCTAssertEqual(store.talking, [])
    }

    func testTypedOnAScreenGoesOutTagged() {
        XCTAssertEqual(ScreenTalk.body("Swap Tuesday", screen: 2), "[yui] screen=2\nSwap Tuesday")
        XCTAssertEqual(ScreenTalk.meta(nil, screen: 2), .object(["screen": .string("2")]))
        // Photos keep their meta, and the screen joins it.
        let withPhotos = ScreenTalk.meta(.object(["photos": .array([.string("a.jpg")])]), screen: 4)
        XCTAssertEqual(withPhotos.object?["screen"], .string("4"))
        XCTAssertNotNil(withPhotos.object?["photos"])
    }

    func testTheBubbleShowsTheWordsAndWhereTheyCameFrom() {
        let meta = ScreenTalk.meta(nil, screen: 2)
        let m = ChatStore.userMessage(id: "u1", body: "[yui] screen=2\nSwap Tuesday\nfor a rest day", meta: meta)
        XCTAssertEqual(m.text, "Swap Tuesday\nfor a rest day")
        XCTAssertEqual(m.fromScreen, 2)
        // A row without the meta is plain words, even if it looks like a tag.
        let plain = ChatStore.userMessage(id: "u2", body: "[yui] screen=2\nhi", meta: nil)
        XCTAssertEqual(plain.text, "[yui] screen=2\nhi")
        XCTAssertNil(plain.fromScreen)
    }
}
