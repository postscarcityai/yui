import XCTest
import YuiLines
@testable import Yui

/// A Dismiss on a Needs you row (YUI-265): the row leaves at once, the host hears it as one quiet event
/// (no chat echo, no agent turn), and a plain tap on the same row is still a tap.
@MainActor final class DismissAskTests: XCTestCase {
    private func store(_ lines: String) -> ChatStore {
        let store = ChatStore()
        store.load([ThreadRow(id: "m1", sender: "agent", body: "```yui\n" + lines + "\n```", kind: "text", meta: nil,
                              createdAt: ISO8601DateFormatter().string(from: .now))])
        return store
    }

    func testDismissLeavesNeedsYouAtOnceWithNoEcho() {
        let s = store("menu review@need-t_0a0b0c \"Outside testers\" sub=\"Do you have one?\"\nmenu review@need-t_0a0b0d \"Pick a look\"")
        XCTAssertEqual(s.menu.review.map(\.id), ["need-t_0a0b0d", "need-t_0a0b0c"])
        s.dismissMenu(s.menu.review.first { $0.id == "need-t_0a0b0c" }!)
        XCTAssertEqual(s.menu.review.map(\.id), ["need-t_0a0b0d"], "only the dismissed row leaves")
        XCTAssertFalse(s.messages.contains { $0.fromUser }, "a Dismiss says nothing in the chat")
    }

    func testTheEventTheHostGets() {
        let e = YLEvent(id: "need-t_0a0b0c", preset: "menu", value: ["bucket": .string("review"), "dismissed": .bool(true)], echo: nil)
        XCTAssertTrue(e.dismisses)
        XCTAssertTrue(e.relays, "it has to reach the host even with no echo")
        XCTAssertEqual(e.line, "[yui] need-t_0a0b0c menu bucket=review dismissed")
        let tap = YLEvent(id: "need-t_0a0b0c", preset: "menu", value: ["bucket": .string("review"), "tapped": .bool(true)], echo: "x")
        XCTAssertFalse(tap.dismisses)
        let quietTick = YLEvent(id: "need-t_0a0b0c", preset: "menu", value: ["bucket": .string("review")], echo: nil)
        XCTAssertFalse(quietTick.relays, "a menu event with no dismiss and no echo stays on the phone")
    }
}
