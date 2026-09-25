import XCTest
import YuiLines
@testable import Yui

/// Replies (YUI-68): what the agent reads, what the row's meta carries, and
/// what a reopened thread shows. Spec: yuigui/spec/RELAY.md.
@MainActor
final class ReplyFormatTests: XCTestCase {
    static let row = "3a6ee9c1-4d97-40dd-901f-e5f0a7db1864"

    func testQuoteIsTheFirstLineOfTheWholeRow() throws {
        let m = ChatMessage(id: "\(Self.row.uppercased())#1", text: "\n  Want me to set up Saturday?  \nSquats first.", fromUser: false)
        let q = try XCTUnwrap(ReplyQuote(m))
        XCTAssertEqual(q.msg, Self.row, "a split reply's bubbles quote their row, lowercased")
        XCTAssertFalse(q.fromUser)
        XCTAssertEqual(q.quote, "Want me to set up Saturday?")
        XCTAssertEqual(q.author(agent: "Urza"), "Urza")
        XCTAssertEqual(ReplyQuote(msg: "x", fromUser: true, quote: "hi").author(agent: "Urza"), "You")
    }

    func testLongLinesAreCut() {
        let long = String(repeating: "a", count: 300)
        XCTAssertEqual(ReplyQuote.firstLine(long), String(repeating: "a", count: ReplyQuote.limit) + "…")
    }

    func testCardsQuoteTheirTitle() throws {
        let m = ChatMessage(text: "", fromUser: false, yl: YLScreen("ask \"Send the invite now?\" \"Yes, send\"|\"Not yet\""))
        XCTAssertEqual(try XCTUnwrap(ReplyQuote(m)).quote, "Send the invite now?")
        XCTAssertEqual(m.words, "Send the invite now?")
        XCTAssertNil(ReplyQuote(ChatMessage(text: "  ", fromUser: true)), "nothing to quote")
        let paged = ChatMessage(text: "", fromUser: false, yl: YLScreen(">2 list Groceries Milk|Eggs\nask \"Send it?\" Yes|No"))
        XCTAssertEqual(try XCTUnwrap(ReplyQuote(paged)).quote, "Send it?", "the card in the chat, not the screen 2 list")
    }

    func testBodyIsTheReplyLineThenTheWords() {
        let q = ReplyQuote(msg: Self.row, fromUser: false, quote: "Say \"yes\" or no")
        XCTAssertEqual(ReplyQuote.body("Yes, do it", replyingTo: q),
                       "[yui] reply to=\(Self.row) from=agent quote=\"Say \\\"yes\\\" or no\"\nYes, do it")
        XCTAssertEqual(ReplyQuote.body("plain", replyingTo: nil), "plain")
        let mine = ReplyQuote(msg: Self.row, fromUser: true, quote: "Milk")
        XCTAssertTrue(ReplyQuote.line(mine).contains(" from=user "))
    }

    func testMetaRoundTripsAndKeepsPhotos() throws {
        let q = ReplyQuote(msg: Self.row, fromUser: false, quote: "First line")
        let photos = Attachments.meta(paths: ["\(UUID().uuidString.lowercased())/\(UUID().uuidString.lowercased())/user/a.jpg"])
        let meta = try XCTUnwrap(ReplyQuote.meta(photos, replyingTo: q))
        XCTAssertEqual(ReplyQuote.from(meta: meta), q)
        XCTAssertEqual(Attachments.paths(meta).count, 1, "the photos stayed in the meta")
        XCTAssertNil(ReplyQuote.meta(nil, replyingTo: nil), "a plain row keeps no meta")
        XCTAssertNil(ReplyQuote.from(meta: .object(["photos": .array([])])))
    }

    func testAReopenedReplyShowsTheWordsAndTheChip() throws {
        let q = ReplyQuote(msg: Self.row, fromUser: false, quote: "Want me to set up Saturday?")
        let m = ChatStore.userMessage(id: "u1", body: ReplyQuote.body("Yes please\nand Sunday", replyingTo: q),
                                      meta: ReplyQuote.meta(nil, replyingTo: q))
        XCTAssertEqual(m.text, "Yes please\nand Sunday", "the reply line is not part of the bubble")
        XCTAssertEqual(m.replyTo, q)
        // A row that only looks like one keeps its words.
        let plain = ChatStore.userMessage(id: "u2", body: "[yui] reply to=x quote=\"y\"\nhi", meta: nil)
        XCTAssertEqual(plain.text, "[yui] reply to=x quote=\"y\"\nhi")
        XCTAssertNil(plain.replyTo)
    }

    func testStartAndCancelAReply() throws {
        let store = ChatStore(messages: [ChatMessage(id: "\(Self.row)#0", text: "Want me to?", fromUser: false)])
        store.startReply("\(Self.row)#0")
        XCTAssertEqual(store.replying?.quote, "Want me to?")
        XCTAssertEqual(store.original(of: try XCTUnwrap(store.replying)), "\(Self.row)#0")
        store.cancelReply()
        XCTAssertNil(store.replying)
    }
}
