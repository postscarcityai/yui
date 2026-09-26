import XCTest
import YuiLines
@testable import Yui

/// The menu button's dot (feedback AI3Pbaid): it reads `waitingCount`, which
/// counts only what still waits on the person. Answered, locked, cleared and
/// done items drop out; backlog and shortcuts never count.
@MainActor
final class WaitingDotTests: XCTestCase {
    static func agent(_ id: String, _ yl: String, at: String) -> ThreadRow {
        ThreadRow(id: id, sender: "agent", body: "```yui\n\(yl)\n```", kind: "text", meta: nil, createdAt: at)
    }

    static func event(_ id: String, _ yl: String, _ preset: String, _ value: [String: YLValue], at: String) -> ThreadRow {
        let meta: [String: YLValue] = ["id": .string(yl), "preset": .string(preset), "value": .object(value),
                                       "echo": .string("tap")]
        return ThreadRow(id: id, sender: "user", body: "[yui] \(yl) \(preset)", kind: "event", meta: .object(meta), createdAt: at)
    }

    /// The war room's shape: every full send clears screen 2 and draws the asks still open.
    static let warRoom: [ThreadRow] = [
        agent("r1", """
        >2
        clear
        choose@need-a "Your call" Yes|No
        choose@need-b "How did it go?" Works|Failed
        choose@need-c "Ship it?" Yes|No
        """, at: "2026-09-26T12:00:00Z"),
    ]

    func testWarRoomAsksCount() {
        let store = ChatStore()
        store.load(Self.warRoom)
        XCTAssertEqual(store.waitingCount, 3)
    }

    func testTappedAskStopsWaitingAtOnce() {
        let store = ChatStore()
        store.load(Self.warRoom + [Self.event("e1", "need-a", "choose", ["choice": .string("Yes")], at: "2026-09-26T12:01:00Z")])
        XCTAssertEqual(store.waitingCount, 2)
    }

    func testAskGoneFromTheNextSendStopsWaiting() {
        // The card finished on the board: the next full send leaves its ask out.
        var store = ChatStore()
        store.load(Self.warRoom + [Self.agent("r2", """
        >2
        clear
        choose@need-c "Ship it?" Yes|No
        """, at: "2026-09-26T12:30:00Z")])
        XCTAssertEqual(store.waitingCount, 1)
        store = ChatStore()
        store.load(Self.warRoom + [Self.agent("r2", ">2\nclear\ncard@status \"Build 160\"", at: "2026-09-26T12:30:00Z")])
        XCTAssertEqual(store.waitingCount, 0)
    }

    func testLockedAskStopsWaiting() {
        let store = ChatStore()
        store.load(Self.warRoom + [Self.agent("r2", "~need-b +lock", at: "2026-09-26T12:30:00Z")])
        XCTAssertEqual(store.waitingCount, 2)
    }

    func testMenuCountsReviewOnlyAndDropsDoneAndTapped() {
        var store = ChatStore()
        let menu = Self.agent("m1", """
        menu review@dana "Invite Dana?"
        menu review@deck "Pick a cover"
        menu backlog@deload "Deload week plan" sub=drafting
        menu shortcut "Start today's workout"
        """, at: "2026-09-26T09:00:00Z")
        store.load([menu])
        XCTAssertEqual(store.waitingCount, 2, "backlog and shortcuts never wait on the person")

        store = ChatStore()
        store.load([menu, Self.agent("m2", "menu done dana", at: "2026-09-26T09:10:00Z")])
        XCTAssertEqual(store.waitingCount, 1)

        let tapped = Self.event("e1", "deck", "menu", ["bucket": .string("review"), "tapped": .bool(true)], at: "2026-09-26T09:05:00Z")
        store = ChatStore()
        store.load([menu, tapped])
        XCTAssertEqual(store.waitingCount, 1, "a tapped review item went to the agent")
        XCTAssertEqual(store.menu.review.count, 2, "it stays in the drawer until menu done")

        // The agent puts it back: it waits again.
        store = ChatStore()
        store.load([menu, tapped, Self.agent("m3", #"menu review@deck "Pick a cover" sub="two left""#, at: "2026-09-26T09:20:00Z")])
        XCTAssertEqual(store.waitingCount, 2)
    }

    func testOldMenuFileStillLoads() throws {
        let old = #"{"lists":{"review":[{"id":"a","label":"A"}],"backlog":[],"shortcut":[]},"at":0}"#
        let menu = try JSONDecoder().decode(AgentMenu.self, from: Data(old.utf8))
        XCTAssertEqual(menu.waiting.map(\.id), ["a"])
    }
}
