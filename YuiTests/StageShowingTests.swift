import XCTest
import YuiLines
@testable import Yui

/// The chat never stays shrunk (YUI-80, TestFlight AFaeNewCPfYfPseXB1jvNq8): it
/// steps back only while the stage has something on it, and a reply with nothing
/// left to draw gets no row.
@MainActor
final class StageShowingTests: XCTestCase {
    static func agent(_ id: String, _ yl: String, at: String) -> ThreadRow {
        ThreadRow(id: id, sender: "agent", body: "```yui\n\(yl)\n```", kind: "text", meta: nil, createdAt: at)
    }

    /// Coach prefers full screen, so a plain question goes up on the stage. A new
    /// look says `screen=chat`: nothing is staged any more, so the stage closes.
    func testANewLookThatUnstagesTheReplyClosesTheStage() throws {
        let store = ChatStore()
        store.style = ["screen": "full"]
        store.load([Self.agent("r1", #"choose "Split?" Push|Pull|Legs"#, at: "2026-09-25T08:00:00Z")])
        let id = try XCTUnwrap(store.messages.last?.id)
        store.openStage(id)
        XCTAssertTrue(store.stageShowing)

        store.style = ["screen": "chat"]
        XCTAssertTrue(store.stageOpen, "precondition: the flag alone is still up")
        XCTAssertFalse(store.stageShowing, "the chat would step back with no stage over it")
        store.settleStage()
        XCTAssertFalse(store.stageOpen)

        // The look goes back: the stage stays closed until someone opens it.
        store.style = ["screen": "full"]
        XCTAssertFalse(store.stageShowing)
    }

    /// The war room from the shelf, then the thread switches agents: nothing stays open.
    func testShelfStageIsShowingAndSettlesWhenTheThreadGoes() {
        let store = ChatStore()
        store.load([Self.agent("r1", ">2\nstat 2 \"Needs you\"\nsave war room", at: "2026-09-25T08:00:00Z")])
        store.reopen("war room")
        XCTAssertTrue(store.stageShowing)
        store.messages.removeAll()
        XCTAssertFalse(store.stageShowing)
        store.settleStage()
        XCTAssertFalse(store.stageOpen)
    }

    /// Every war room refresh starts `>2 clear`, which empties the last one: that
    /// reply is blank and gets no row (the two lone faces in the feedback shot).
    func testARefreshedWarRoomLeavesNoBlankRow() {
        let room = ">2\nclear\nstat 2 \"Needs you\"\ncard \"APP lane\" sub=Idle\nsave war room"
        let store = ChatStore()
        store.load([
            Self.agent("r1", room, at: "2026-09-25T08:00:00Z"),
            Self.agent("r2", room, at: "2026-09-25T08:10:00Z"),
            Self.agent("r3", "~card sub=Busy", at: "2026-09-25T08:20:00Z"),
        ])
        XCTAssertEqual(store.messages.map { $0.yl?.isBlank }, [true, false, true])
        XCTAssertEqual(store.onPage(2).count, 1, "screen 2 still shows the newest war room")
    }

    func testAScreenWithSomethingOnItIsNotBlank() {
        let store = ChatStore()
        store.load([
            Self.agent("r1", "say Hi", at: "2026-09-25T08:00:00Z"),
            Self.agent("r2", ">3\nstat 5 Cards", at: "2026-09-25T08:01:00Z"),
            Self.agent("r3", "theme accent=#7B5CFF", at: "2026-09-25T08:02:00Z"),
            Self.agent("r4", "timer 5m Plank", at: "2026-09-25T08:03:00Z"),
        ])
        XCTAssertEqual(store.messages.map { $0.yl?.isBlank }, [false, false, false, false])
    }
}
