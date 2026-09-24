import XCTest
import YuiLines
@testable import Yui

/// Reactions (YUI-49): what the agent reads, what the server gets, and what a
/// reopened thread shows. Spec: yuigui/spec/REACTIONS.md.
@MainActor
final class ReactionFormatTests: XCTestCase {
    static let row = "3a6ee9c1-4d97-40dd-901f-e5f0a7db1864"
    let up = Reaction.all[0]

    func testTheSixMatchTheSpec() {
        XCTAssertEqual(Reaction.all.map(\.emoji), ["👍", "👎", "🤔", "❤️", "⏳", "🔥"])
        XCTAssertEqual(Reaction.all.map(\.meaning), ["build it", "no", "not sure", "love it", "later", "priority"])
    }

    func testBodyIsTheEventLineThenTheQuote() {
        XCTAssertEqual(Reaction.body(msg: Self.row, reaction: up, changed: false, quoting: "Want me to set it up?"),
                       "[yui] react msg=\(Self.row) emoji=👍 meaning=\"build it\"\n> Want me to set it up?")
        XCTAssertEqual(Reaction.body(msg: Self.row, reaction: Reaction.all[5], changed: true, quoting: ""),
                       "[yui] react msg=\(Self.row) emoji=🔥 meaning=priority changed=true")
        XCTAssertEqual(Reaction.body(msg: Self.row, reaction: nil, changed: false, quoting: "Hi"),
                       "[yui] react msg=\(Self.row) emoji=none\n> Hi")
    }

    func testQuoteIsCappedAndEveryLineMarked() {
        let long = String(repeating: "a", count: 300)
        let q = Reaction.quote(message: long)
        XCTAssertEqual(q, "> " + String(repeating: "a", count: 200) + "…")
        XCTAssertEqual(Reaction.quote(message: "one\n\ntwo "), "> one\n> two")
    }

    func testMetaRoundTrips() throws {
        let meta = Reaction.meta(msg: Self.row, reaction: up)
        let back = try XCTUnwrap(Reaction.from(meta: meta))
        XCTAssertEqual(back.msg, Self.row)
        XCTAssertEqual(back.emoji, "👍")
        XCTAssertNil(try XCTUnwrap(Reaction.from(meta: Reaction.meta(msg: Self.row, reaction: nil))).emoji)
        XCTAssertNil(Reaction.from(meta: .object(["id": .string("n1")])), "a tap is not a reaction")
    }

    /// Reopened: the column puts the badge back, and a later react row wins.
    func testReopenedThreadShowsTheNewestReaction() {
        let store = ChatStore()
        var agentRow = ThreadRow(id: Self.row.uppercased(), sender: "agent", body: "Want me to set it up?", kind: "text",
                                 meta: nil, createdAt: "2026-09-24T12:00:00+00:00")
        agentRow.reaction = "👍"
        store.load([agentRow])
        let bubble = try! XCTUnwrap(store.messages.first)
        XCTAssertEqual(bubble.rowID, Self.row)
        XCTAssertTrue(store.wearsReaction(bubble))
        XCTAssertEqual(store.reaction(for: bubble), up)

        let change = ThreadRow(id: UUID().uuidString, sender: "user", body: "[yui] react", kind: "event",
                               meta: Reaction.meta(msg: Self.row, reaction: Reaction.all[3]),
                               createdAt: "2026-09-24T12:01:00+00:00")
        store.load([change])
        XCTAssertEqual(store.reaction(for: bubble)?.emoji, "❤️")
        XCTAssertEqual(store.messages.count, 1, "a react row draws no bubble")
    }

    /// Demo chat (no thread): the same one again takes it back, another replaces it.
    func testTappingTheSameOneTakesItBack() {
        let store = ChatStore(messages: [ChatMessage(id: "a#0", text: "Plan?", fromUser: false),
                                         ChatMessage(id: "a#1", text: "Or later?", fromUser: false),
                                         ChatMessage(id: "u", text: "hi", fromUser: true)])
        store.react("a#0", with: up)
        XCTAssertEqual(store.reaction(for: store.messages[1]), up, "one reaction per row, on either bubble")
        XCTAssertFalse(store.wearsReaction(store.messages[0]))
        XCTAssertTrue(store.wearsReaction(store.messages[1]), "the row's last bubble wears the badge")
        store.react("a#1", with: Reaction.all[1])
        XCTAssertEqual(store.reaction(for: store.messages[0])?.emoji, "👎")
        store.react("a#1", with: Reaction.all[1])
        XCTAssertNil(store.reaction(for: store.messages[0]))
        store.react("u", with: up)
        XCTAssertNil(store.reaction(for: store.messages[2]), "your own messages take none")
    }
}
