import XCTest
@testable import Yui

/// Long turns (TestFlight: "assume it's always going to take a little while",
/// and no telling it to restart every time). The chat says the agent is
/// working and for how long, resumes that on reopen, and has no time limit.
@MainActor
final class WorkingNoteTests: XCTestCase {
    static func ts(_ ago: TimeInterval) -> String { Date.now.addingTimeInterval(-ago).formatted(.iso8601) }

    static func user(_ id: String, sent: TimeInterval, pickedUp: TimeInterval? = nil, done: TimeInterval? = nil) -> ThreadRow {
        ThreadRow(id: id, sender: "user", body: "OK, show me my weight chart", kind: "text", meta: nil,
                  createdAt: ts(sent), deliveredAt: pickedUp.map(ts), handledAt: done.map(ts))
    }

    static let reply = ThreadRow(id: "a1", sender: "agent", body: "Quick one on Yui itself.", kind: "text", meta: nil,
                                 createdAt: ts(600))

    func testLabelCountsUp() {
        let now = Date.now
        XCTAssertEqual(WorkingNote.label(name: "Yui", since: now.addingTimeInterval(-9), pickedUp: nil, now: now), "Sent to Yui · 9s")
        XCTAssertEqual(WorkingNote.label(name: "Yui", since: now.addingTimeInterval(-90), pickedUp: now.addingTimeInterval(-84), now: now),
                       "Yui is working · 1m 24s")
        XCTAssertEqual(WorkingNote.elapsed(3 * 3600 + 7 * 60 + 5), "3h 7m")
        XCTAssertEqual(WorkingNote.elapsed(-2), "0s")
    }

    func testReopenedMidTurnKeepsWorking() {
        let store = ChatStore()
        store.load([Self.reply, Self.user("u1", sent: 100, pickedUp: 95)])
        XCTAssertTrue(store.waiting, "a thread reopened mid-turn shows no working note")
        let picked = try! XCTUnwrap(store.pickedUpAt)
        XCTAssertEqual(Date.now.timeIntervalSince(picked), 95, accuracy: 2)
    }

    func testLongTurnHasNoTimeLimit() {
        let store = ChatStore()
        store.load([Self.reply, Self.user("u1", sent: 20 * 60, pickedUp: 20 * 60 - 3)])
        XCTAssertTrue(store.waiting, "a 20 minute turn stopped showing as working")
    }

    func testFinishedOrStaleTurnsDoNotWait() {
        let done = ChatStore()
        done.load([Self.reply, Self.user("u1", sent: 100, pickedUp: 95, done: 40)])
        XCTAssertFalse(done.waiting, "a finished turn still shows as working")

        let stale = ChatStore()
        stale.load([Self.reply, Self.user("u1", sent: 2 * 3600)])
        XCTAssertFalse(stale.waiting, "a two hour old unanswered row reads as working")

        let answered = ChatStore()
        answered.load([Self.user("u1", sent: 700, pickedUp: 699), ThreadRow(id: "a2", sender: "agent", body: "Here.", kind: "text",
                                                                           meta: nil, createdAt: Self.ts(650))])
        XCTAssertFalse(answered.waiting)
    }
}
