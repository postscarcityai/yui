import XCTest
import YuiLines
@testable import Yui

/// Hold to snap and say (YUI-166): `yui://snap` opens it in the thread on screen, from a
/// link or a drawer shortcut (`menu shortcut "Log a meal" url=yui://snap`, Basil's).
@MainActor
final class SnapLinkTests: XCTestCase {
    func testSnapLinks() {
        XCTAssertTrue(PushCenter.isSnap(URL(string: "yui://snap")!))
        XCTAssertFalse(PushCenter.isSnap(URL(string: "https://www.yuigui.com/snap")!))
        XCTAssertFalse(PushCenter.isSnap(URL(string: "yui://settings")!))
    }

    func testOpeningItLeavesItForTheChat() {
        let push = PushCenter.shared
        XCTAssertTrue(push.open(URL(string: "yui://snap")!))
        XCTAssertTrue(push.pendingSnap)
        XCTAssertNil(push.pendingAgentID)
        XCTAssertNil(push.pendingSettings)
        push.pendingSnap = false
    }

    func testAShortcutOpensItWithNoMessage() {
        let store = ChatStore()
        let item = YLMenuItem(id: "meal", label: "Log a meal", url: "yui://snap")
        var composed: String?
        MenuAction.shortcut(item, store: store) { composed = $0 }
        XCTAssertTrue(PushCenter.shared.pendingSnap, "the shortcut did not open the camera")
        XCTAssertNil(composed)
        XCTAssertTrue(store.messages.isEmpty, "the shortcut sent its label as a message")
        PushCenter.shared.pendingSnap = false
    }
}
