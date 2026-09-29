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
}
