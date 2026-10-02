import XCTest
import YuiLines
@testable import Yui

/// The stage's end screen ("Anything else?") never shows while a turn is in flight (TestFlight
/// APO8y7eU_NQKRDyLpUdwhX0). The store keeps waiting until the reply to the person's row lands.
@MainActor
final class StageInFlightTests: XCTestCase {
    private func iso(_ ago: TimeInterval = 0) -> String { Date.now.addingTimeInterval(-ago).formatted(.iso8601) }

    private func user(_ id: String, handled: TimeInterval? = nil) -> ThreadRow {
        ThreadRow(id: id, sender: "user", body: "hi", kind: "text", meta: nil, createdAt: iso(60),
                  deliveredAt: iso(55), handledAt: handled.map { iso($0) })
    }

    private func agent(_ id: String, turn: [String]?) -> ThreadRow {
        let meta: YLValue? = turn.map { .object(["turn": .array($0.map { .string($0) })]) }
        return ThreadRow(id: id, sender: "agent", body: "ok", kind: "text", meta: meta, createdAt: iso())
    }

    func testAThreadOpenedMidTurnIsInFlight() {
        let store = ChatStore()
        store.load([user("u1")])
        XCTAssertTrue(store.inFlight)
        XCTAssertEqual(store.waitingRow, "u1")
    }

    func testAJustHandledTurnStaysInFlightUntilTheGraceEnds() {
        let recent = ChatStore()
        recent.load([user("u1", handled: 3)])
        XCTAssertTrue(recent.inFlight, "its reply may still be landing")
        let old = ChatStore()
        old.load([user("u1", handled: 120)])
        XCTAssertFalse(old.inFlight, "handed back long ago with no reply: the turn is over")
    }

    func testAnotherTurnsReplyDoesNotEndTheWait() {
        let store = ChatStore()
        store.load([user("u2")])
        store.load([agent("a1", turn: ["u1"])])
        XCTAssertTrue(store.inFlight, "a late reply to an earlier turn ended this one")
        store.load([agent("a2", turn: ["U2"])])
        XCTAssertFalse(store.inFlight, "the reply to this turn left the stage waiting")
    }

    func testAReplyNamingNoTurnEndsTheWait() {
        let store = ChatStore()
        store.load([user("u1")])
        store.load([agent("a1", turn: nil)])
        XCTAssertFalse(store.inFlight)
    }

    func testOnlyTheWaitedForRowIsTracked() {
        XCTAssertTrue(ChatStore.tracks("U1", waiting: "u1"))
        XCTAssertFalse(ChatStore.tracks("u0", waiting: "u1"), "an older finished row says nothing of this turn")
        XCTAssertTrue(ChatStore.tracks("u0", waiting: nil))
    }
}

/// A turn nobody answered is a failure the stage names, with Try again (TestFlight AClUWC-D8VpsUHE98ZgCDik).
@MainActor
final class StageUnansweredTests: XCTestCase {
    private func msg(_ id: String, user: Bool, _ text: String) -> ChatMessage {
        ChatMessage(id: id, text: text, fromUser: user)
    }

    func testAnAskWithNoReplyIsUnanswered() {
        let t = StageChunks.turn([msg("u1", user: true, "explain string theory")], ask: nil)
        XCTAssertTrue(t.unanswered)
    }

    func testATextReplyIsAnAnswer() {
        let t = StageChunks.turn([msg("u1", user: true, "explain string theory"), msg("a1", user: false, "Tiny strings.")], ask: nil)
        XCTAssertFalse(t.unanswered)
    }

    func testAHelloIsNotUnanswered() {
        XCTAssertFalse(StageTurn(hello: true).unanswered)
    }
}
