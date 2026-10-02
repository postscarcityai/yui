import XCTest
@testable import Yui

/// A tap on a notification (YUI-199): the payload the server sends (supabase/functions/yui-push/payload.ts)
/// names the agent, the chat and the message, and the app keeps all three for the thread to land on.
@MainActor
final class PushTapTests: XCTestCase {
    override func setUp() {
        let p = PushCenter.shared
        p.pendingAgentID = nil; p.pendingChatID = nil; p.pendingMessageID = nil
    }

    override func tearDown() {
        let p = PushCenter.shared
        p.pendingAgentID = nil; p.pendingChatID = nil; p.pendingMessageID = nil
    }

    func testTheTapKeepsTheAgentTheChatAndTheMessage() {
        PushCenter.shared.tapped(["agent_id": "basil", "message_id": "m-7", "chat": "C-1", "url": "yui://agent/basil/thread"])
        XCTAssertEqual(PushCenter.shared.pendingAgentID, "basil")
        XCTAssertEqual(PushCenter.shared.pendingMessageID, "m-7")
        XCTAssertEqual(PushCenter.shared.pendingChatID, "c-1")
    }

    func testAPayloadWithOnlyTheLinkStillNamesTheAgent() {
        PushCenter.shared.tapped(["url": "yui://agent/luna/thread"])
        XCTAssertEqual(PushCenter.shared.pendingAgentID, "luna")
    }

    func testASettingsLinkOpensSettingsNotTheAgent() {
        PushCenter.shared.tapped(["agent_id": "basil", "url": "yui://settings/search"])
        XCTAssertNil(PushCenter.shared.pendingAgentID)
        XCTAssertEqual(PushCenter.shared.pendingSettings, "search")
        PushCenter.shared.pendingSettings = nil
    }

    /// Three things came in a row and the tap names none of them: it lands on the first, not the last.
    func testAnUnnamedMessageLandsOnTheFirstOfTheNewestTurn() {
        let ask = ChatMessage(id: "u", text: "hi", fromUser: true)
        let a = ChatMessage(id: "a", text: "One", fromUser: false)
        let b = ChatMessage(id: "b", text: "Two", fromUser: false)
        let c = ChatMessage(id: "c", text: "Three", fromUser: false)
        let old = ChatMessage(id: "old", text: "Earlier", fromUser: false)
        XCTAssertEqual(PushLanding.message([old, ask, a, b, c], want: nil), "a")
        XCTAssertEqual(PushLanding.message([old, ask, a, b, c], want: "gone"), "a")
        XCTAssertEqual(PushLanding.message([old, ask, a, b, c], want: "b"), "b")
        XCTAssertEqual(PushLanding.message([a, b], want: nil), "a")
        XCTAssertNil(PushLanding.message([ask], want: nil))
    }

    /// Thread rows are `<message id>#<part>`; the push names the bare id (YUI-262: the tap never matched, so it
    /// opened the first thing in the turn, or just the home).
    func testThePushNamesTheBareMessageIdNotTheRow() {
        let ask = ChatMessage(id: "u", text: "hi", fromUser: true)
        let old = ChatMessage(id: "m1#0", text: "Earlier", fromUser: false)
        let a = ChatMessage(id: "m2#0", text: "One", fromUser: false)
        let b = ChatMessage(id: "m3#0", text: "Two", fromUser: false)
        let b2 = ChatMessage(id: "m3#1", text: "Two b", fromUser: false)
        XCTAssertEqual(PushLanding.message([ask, old, a, b, b2], want: "m3"), "m3#0", "the first part of the message it names")
        XCTAssertEqual(PushLanding.message([ask, old, a, b], want: "M2"), "m2#0")
        XCTAssertTrue(PushLanding.isRow("m3#1", "m3"))
        XCTAssertFalse(PushLanding.isRow("m33#0", "m3"), "m33 is another message")
    }

    /// A reply that lands while the home is up (YUI-262): the first thing the agent said among the new rows.
    func testArrivalIsTheFirstAgentRowAmongTheNew() {
        let mine = ChatMessage(id: "u", text: "hi", fromUser: true)
        let a = ChatMessage(id: "a", text: "One", fromUser: false)
        let b = ChatMessage(id: "b", text: "Two", fromUser: false)
        XCTAssertEqual(PushLanding.arrival([a, b]), "a")
        XCTAssertEqual(PushLanding.arrival([mine, b]), "b")
        XCTAssertNil(PushLanding.arrival([mine]), "my own row opens nothing")
        XCTAssertNil(PushLanding.arrival([]))
    }

    /// A reply with no turn of mine before it and no hello (another channel, a thread nobody spoke in) plays from itself.
    func testAReplyNobodyAnsweredPlaysFromItself() {
        let a = ChatMessage(id: "a", text: "First news.", fromUser: false)
        let b = ChatMessage(id: "b", text: "More news.", fromUser: false)
        let model = StageFirstModel()
        XCTAssertTrue(model.show(reply: "a", in: [a, b]))
        XCTAssertEqual(model.hello, "a")
        XCTAssertEqual(model.turn([a, b])?.hello, true)
        XCTAssertGreaterThan(model.turn([a, b])?.chunks.count ?? 0, 0, "both rows play")
        XCTAssertTrue(model.show(reply: "b", in: [a, b]))
        XCTAssertEqual(model.hello, "b")
    }
}
