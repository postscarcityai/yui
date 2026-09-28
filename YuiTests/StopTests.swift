import XCTest
import YuiLines
@testable import Yui

/// Stop (YUI-190). Chris on TestFlight: "I actually do want to be able to cancel. While it's
/// working in the back, I might be doing the wrong thing." The store knows when the agent is on
/// something (a turn, or a job behind "Got it, working out the macros"), a Stop ends it with a
/// quiet note, and whatever answers the stopped work later never lands, now or on a reopen.
@MainActor
final class StopTests: XCTestCase {
    static func ts(_ ago: TimeInterval) -> String { Date.now.addingTimeInterval(-ago).formatted(.iso8601) }

    static func user(_ id: String, _ ago: TimeInterval, done: Bool = false) -> ThreadRow {
        ThreadRow(id: id, sender: "user", body: "Plan my week", kind: "text", meta: nil, createdAt: ts(ago),
                  deliveredAt: ts(ago - 1), handledAt: done ? ts(ago - 2) : nil)
    }

    static func agent(_ id: String, _ ago: TimeInterval, body: String = "Here.", meta: YLValue? = nil) -> ThreadRow {
        ThreadRow(id: id, sender: "agent", body: body, kind: "text", meta: meta, createdAt: ts(ago))
    }

    static func stop(_ id: String, _ ago: TimeInterval) -> ThreadRow {
        ThreadRow(id: id, sender: "user", body: "stop", kind: "control", meta: .object(["op": .string("stop")]), createdAt: ts(ago))
    }

    static func turn(_ ids: String...) -> YLValue { .object(["turn": .array(ids.map { .string($0) })]) }

    static func meal(_ job: String, queued: Bool, turn: String? = nil) -> YLValue {
        var native: [String: YLValue] = ["meal": .string(job)]
        if queued { native["queued"] = .bool(true) }
        var o: [String: YLValue] = ["native": .object(native)]
        if let turn { o["turn"] = .array([.string(turn)]) }
        return .object(o)
    }

    func testTheStopControlIsOnlyThePersons() {
        XCTAssertTrue(ChatStore.isStop(Self.stop("s1", 1)))
        XCTAssertFalse(ChatStore.isStop(ThreadRow(id: "c", sender: "agent", body: "controls: stop", kind: "control",
                                                  meta: .object(["op": .string("stop")]), createdAt: Self.ts(1))))
        XCTAssertFalse(ChatStore.isStop(ThreadRow(id: "c", sender: "user", body: "controls: list soul", kind: "control",
                                                  meta: .object(["op": .string("list")]), createdAt: Self.ts(1))))
    }

    func testAMidTurnThreadIsWorkingAndAStopEndsIt() {
        let store = ChatStore()
        store.load([Self.agent("a0", 600), Self.user("u1", 20)])
        XCTAssertTrue(store.waiting)
        XCTAssertTrue(store.working, "a turn in flight can be stopped")
        store.load([Self.stop("s1", 10)])
        XCTAssertFalse(store.waiting, "Stop ends the wait at once")
        XCTAssertFalse(store.working)
        let note = store.messages.last!
        XCTAssertTrue(note.stopped)
        XCTAssertEqual(note.text, "Stopped")
        XCTAssertFalse(note.fromUser)
    }

    func testTheStoppedTurnsLateReplyNeverLands() {
        let store = ChatStore()
        store.load([Self.agent("a0", 600), Self.user("u1", 30), Self.stop("s1", 20),
                    Self.agent("late", 10, body: "Here's your week, half done.", meta: Self.turn("u1"))])
        XCTAssertFalse(store.messages.contains { $0.text.contains("half done") }, "the late reply landed")
        XCTAssertEqual(store.messages.filter(\.stopped).count, 1)
        // Something new after the stop still lands.
        store.load([Self.user("u2", 5), Self.agent("a2", 4, body: "Sure, starting over.", meta: Self.turn("u2"))])
        XCTAssertTrue(store.messages.contains { $0.text == "Sure, starting over." })
        XCTAssertFalse(store.working)
    }

    func testTheStopReadBackTwiceIsOneNote() {
        let store = ChatStore()
        store.load([Self.user("u1", 30), Self.stop("s1", 20)])
        store.load([Self.stop("s1", 20)])  // the next poll overlaps
        XCTAssertEqual(store.messages.filter(\.stopped).count, 1)
    }

    func testAMealJobKeepsTheAgentWorkingUntilItsAnswer() {
        let store = ChatStore()
        store.load([Self.user("p1", 30, done: true),
                    Self.agent("ack", 29, body: "Got it, working out the macros.", meta: Self.meal("j1", queued: true, turn: "p1"))])
        XCTAssertFalse(store.waiting, "the answer is in")
        XCTAssertTrue(store.working, "the macros are still being worked out")
        XCTAssertEqual(store.job, "j1")
        store.load([Self.agent("bd", 5, body: "Salmon bowl, 640 kcal.", meta: Self.meal("j1", queued: false, turn: "p1"))])
        XCTAssertFalse(store.working)
        XCTAssertNil(store.job)
    }

    func testStopDuringTheMacrosDropsTheBreakdown() {
        let store = ChatStore()
        store.load([Self.user("p1", 30, done: true),
                    Self.agent("ack", 29, body: "Got it, working out the macros.", meta: Self.meal("j1", queued: true, turn: "p1")),
                    Self.stop("s1", 20),
                    Self.agent("bd", 5, body: "Salmon bowl, 640 kcal.", meta: Self.meal("j1", queued: false, turn: "p1"))])
        XCTAssertFalse(store.working)
        XCTAssertFalse(store.messages.contains { $0.text.contains("640 kcal") }, "the stopped job's breakdown landed")
        XCTAssertTrue(store.messages.contains { $0.text == "Got it, working out the macros." }, "what landed before stays")
    }

    func testAnOldQueuedJobIsNotWork() {
        let store = ChatStore()
        store.load([Self.agent("ack", 3600, body: "Got it, working out the macros.", meta: Self.meal("j1", queued: true))])
        XCTAssertFalse(store.working, "an hour-old job with no answer is not still running")
    }

    func testReopenedAfterAStopDoesNotResumeWaiting() {
        let store = ChatStore()
        store.load([Self.user("u1", 30), Self.stop("s1", 20)])
        XCTAssertFalse(store.waiting, "a thread whose newest row is a Stop is not mid-turn")
    }

    func testTheStageTurnIsStoppedAndHasNoChunkForTheNote() {
        let store = ChatStore()
        store.load([Self.user("u1", 30), Self.stop("s1", 20)])
        let t = StageChunks.turn(store.messages, ask: nil)
        XCTAssertTrue(t.stopped)
        XCTAssertEqual(t.pages, 0, "Stopped is a note in the record, not an answer on the stage")
    }

    func testTheDemoStopCancelsTheScriptedAnswer() async throws {
        UserDefaults.standard.set(0.1, forKey: "yuiDemoPickupAfter")
        UserDefaults.standard.set(0.6, forKey: "yuiDemoReplyAfter")
        defer {
            UserDefaults.standard.removeObject(forKey: "yuiDemoPickupAfter")
            UserDefaults.standard.removeObject(forKey: "yuiDemoReplyAfter")
        }
        let store = ChatStore()
        store.messages.append(ChatMessage(text: "Plan my week", fromUser: true))
        store.demoAnswer("Too late.")
        XCTAssertTrue(store.working)
        store.stop()
        XCTAssertFalse(store.working)
        try await Task.sleep(for: .seconds(1.2))
        XCTAssertEqual(store.messages.filter { !$0.fromUser && !$0.stopped }.count, 0, "the scripted answer landed after Stop")
        XCTAssertEqual(store.messages.last?.stopped, true)
    }
}
