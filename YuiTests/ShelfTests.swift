import XCTest
import YuiLines
@testable import Yui

/// Saved screens and the shelf (YUI-32, spec YL.md section 5): a `save` in one
/// reply, a two-token `show` in a later one, and a shelf rebuilt from the thread.
@MainActor
final class ShelfTests: XCTestCase {
    static func agent(_ id: String, _ yl: String, at: String) -> ThreadRow {
        ThreadRow(id: id, sender: "agent", body: "```yui\n\(yl)\n```", kind: "text", meta: nil, createdAt: at)
    }

    static let rows: [ThreadRow] = [
        agent("r1", """
        >full
        timer@hiit 20/10x8 Tabata
        ask "Log it?"
        save busy day
        close
        """, at: "2026-09-24T10:00:00Z"),
        agent("r2", """
        form "Check-in" sleep:1-10
        save check-in
        """, at: "2026-09-24T11:00:00Z"),
        agent("r3", "show busy day", at: "2026-09-25T09:00:00Z"),
    ]

    func testShowInALaterReplyComesFromTheShelf() {
        let store = ChatStore()
        store.load(Self.rows)
        XCTAssertEqual(store.shelf.screens.map(\.name), ["check-in", "busy day"])
        XCTAssertTrue(store.shelf["busy day"]?.stage == true)
        let back = store.messages.last?.yl
        XCTAssertEqual(back?.errors.count, 0)
        // Saved from the stage, back on the stage, tagged with its name.
        XCTAssertEqual(back?.components.map(\.ylID), ["hiit", "n1"])
        XCTAssertEqual(back?.components.map(\.screen), ["full", "full"])
        XCTAssertEqual(back?.components.first?.props["rounds"], .number(8))
        let e = back?.components.first?.event(["done": .bool(true)])
        XCTAssertEqual(e?.value["saved"], .string("busy day"))
    }

    func testForgetAndRemove() {
        let store = ChatStore()
        store.load(Self.rows + [Self.agent("r4", "forget check-in", at: "2026-09-25T10:00:00Z")])
        XCTAssertEqual(store.shelf.screens.map(\.name), ["busy day"])
        store.unshelve("busy day")
        XCTAssertTrue(store.shelf.screens.isEmpty)
    }

    func testOlderSaveNeverOverwritesANewerOne() {
        var shelf = Shelf()
        let new = SavedScreen(name: "w", components: [], stage: true)
        let old = SavedScreen(name: "w", components: [], stage: false)
        XCTAssertTrue(shelf.apply(.save(new), at: Date(timeIntervalSince1970: 200)))
        XCTAssertFalse(shelf.apply(.save(old), at: Date(timeIntervalSince1970: 100)))
        XCTAssertEqual(shelf["w"]?.stage, true)
        // Removed by hand: only a save written later brings it back.
        shelf.remove("w", at: Date(timeIntervalSince1970: 300))
        XCTAssertFalse(shelf.apply(.save(new), at: Date(timeIntervalSince1970: 250)))
        XCTAssertTrue(shelf.apply(.save(new), at: Date(timeIntervalSince1970: 400)))
    }

    func testTapOnTheShelfOpensTheStage() {
        let store = ChatStore()
        store.load(Self.rows)
        store.reopen("check-in")
        XCTAssertTrue(store.stageOpen)
        XCTAssertEqual(store.stageMessage?.yl?.components.map(\.preset), ["form"])
        XCTAssertEqual(store.stageMessage?.yl?.components.first?.screen, "full")
    }

    func testShelfSurvivesTheDisk() throws {
        var shelf = Shelf()
        shelf.apply(.save(SavedScreen(name: "leg day", components: [], stage: false)), at: .now)
        let id = "test-\(UUID().uuidString)"
        shelf.store(agentID: id)
        defer { try? FileManager.default.removeItem(at: Shelf.file(agentID: id)) }
        XCTAssertEqual(Shelf.load(agentID: id).screens.map(\.name), ["leg day"])
    }
}
