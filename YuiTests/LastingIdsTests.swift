import XCTest
import YuiLines
@testable import Yui

/// Ids that last (YUI-75, spec YL.md section 5): an explicit id on a page stays
/// addressable from later replies, so the war room patches one ask or one lane
/// on page 2 instead of re-sending the whole page.
@MainActor
final class LastingIdsTests: XCTestCase {
    static func agent(_ id: String, _ yl: String, at: String) -> ThreadRow {
        ThreadRow(id: id, sender: "agent", body: "```yui\n\(yl)\n```", kind: "text", meta: nil, createdAt: at)
    }

    static let board = agent("r1", """
    >2
    choose@need-t_a "Ship it?" Yes|No
    choose@need-t_b "Merge it?" Yes|No
    timeline@war
    now@lane-app "YUI-54 drawer"
    list Scratch A|B
    >1
    card@chat-card Hello
    """, at: "2026-09-25T10:00:00Z")

    func component(_ store: ChatStore, _ id: String) -> YLComponent? {
        store.messages.compactMap(\.yl).flatMap(\.components).last { $0.ylID == id }
    }

    func testExplicitIdsOnAPageLast() {
        let store = ChatStore()
        store.load([Self.board])
        XCTAssertEqual(store.lastingIds, ["need-t_a": "choose", "need-t_b": "choose", "war": "timeline", "lane-app": "now"],
                       "auto ids and ids in the chat do not last")
    }

    func testALaterReplyPatchesOneOfManyById() {
        let store = ChatStore()
        store.load([Self.board, Self.agent("r2", """
        ~need-t_a +lock
        ~lane-app "Build 106 is VALID"
        """, at: "2026-09-25T10:05:00Z")])
        XCTAssertEqual(component(store, "need-t_a")?.props["lock"], .bool(true))
        XCTAssertNil(component(store, "need-t_b")?.props["lock"], "the newest choose is not the one hit")
        XCTAssertEqual(component(store, "lane-app")?.props["text"], .string("Build 106 is VALID"))
        XCTAssertTrue(store.messages.compactMap(\.yl).allSatisfy { $0.errors.isEmpty })
    }

    func testThePatchReachesTheSavedCopyButNotANewerSave() {
        let saved = Self.agent("r1", """
        >2
        choose@need-t_a "Ship it?" Yes|No
        stat@mvp 60% "MVP shipped"
        save war room
        """, at: "2026-09-25T10:00:00Z")
        let patch = Self.agent("r2", "~need-t_a +lock\n~mvp 64%", at: "2026-09-25T10:05:00Z")
        let store = ChatStore()
        store.load([saved, patch])
        let parts = store.shelf["war room"]?.parts ?? []
        XCTAssertEqual(parts.first { $0.ylID == "need-t_a" }?.props["lock"], .bool(true))
        XCTAssertEqual(parts.first { $0.ylID == "mvp" }?.props["value"], .number(64))

        // A newer full send saved again: replaying the older patch leaves it alone.
        let resent = Self.agent("r3", """
        >2 clear
        >2 choose@need-t_a "Ship it?" Yes|No
        >2 save war room
        """, at: "2026-09-25T10:10:00Z")
        var shelf = Shelf()
        shelf.apply(.save(SavedScreen(name: "war room", components: YLScreen(">2 choose@need-t_a \"Ship it?\" Yes|No").components,
                                      stage: false)), at: YuiTime.date(resent.createdAt)!)
        XCTAssertFalse(shelf.patch(YuiLines.parse("~need-t_a +lock", known: ["need-t_a": "choose"])[0],
                                   at: YuiTime.date(patch.createdAt)!))
        XCTAssertNil(shelf["war room"]?.parts.first?.props["lock"])
    }

    /// YUI-111: `kind=` moves a timeline row in place, on the page and in the
    /// saved copy, and the id answers to its new kind from then on.
    func testAPatchMovesATimelineRowInPlace() {
        let saved = Self.agent("r1", """
        >2
        timeline@war
        done@rel-a "Saved screens"
        now@rel-b "Reply to a message"
        next@rel-c "Each agent's home"
        save war room
        """, at: "2026-09-25T10:00:00Z")
        let moved = Self.agent("r2", "~rel-b kind=done at=\"Sep 26\"\n~rel-c kind=now", at: "2026-09-25T10:05:00Z")
        let store = ChatStore()
        store.load([saved, moved])
        let rows = store.messages.compactMap(\.yl).flatMap(\.components).filter { timelineRows.contains($0.preset) }
        XCTAssertEqual(rows.map(\.ylID), ["rel-a", "rel-b", "rel-c"], "rows keep their place")
        XCTAssertEqual(rows.map(\.preset), ["done", "done", "now"])
        XCTAssertEqual(markAt(rows.map(\.preset)), 2, "the now marker moved down one")
        XCTAssertEqual(component(store, "rel-b")?.props["at"], .string("Sep 26"))
        XCTAssertNil(component(store, "rel-b")?.props["kind"], "kind= is the preset, not a prop")
        XCTAssertEqual(store.lastingIds["rel-b"], "done")
        XCTAssertEqual(store.shelf["war room"]?.parts.map(\.preset), ["timeline", "done", "done", "now"])
        XCTAssertTrue(store.messages.compactMap(\.yl).allSatisfy { $0.errors.isEmpty })

        // A later reply reaches it by its new kind, not its old one.
        store.load([saved, moved, Self.agent("r3", "~done@rel-b sub=shipped", at: "2026-09-25T10:06:00Z")])
        XCTAssertEqual(component(store, "rel-b")?.props["sub"], .string("shipped"))
    }

    func testAClearedPageTakesItsIdsWithIt() {
        let store = ChatStore()
        store.load([Self.board, Self.agent("r2", ">2 clear", at: "2026-09-25T10:05:00Z"),
                    Self.agent("r3", "~need-t_a +lock", at: "2026-09-25T10:06:00Z")])
        XCTAssertEqual(store.lastingIds, [:])
        XCTAssertEqual(store.messages.compactMap(\.yl).flatMap(\.errors).count, 1, "nothing called need-t_a any more")
    }
}
