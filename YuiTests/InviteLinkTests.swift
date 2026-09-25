import XCTest
@testable import Yui

/// Invite links and typed codes (YUI-56): which URLs carry a code, and how a
/// code is cleaned up before it goes to yui-auth.
@MainActor
final class InviteLinkTests: XCTestCase {
    func code(_ s: String) -> String? { Account.inviteCode(in: URL(string: s)!) }

    func testLinksThatCarryACode() {
        XCTAssertEqual(code("https://www.yuigui.com/i/ABCDE-FGHJK"), "ABCDE-FGHJK")
        XCTAssertEqual(code("https://yuigui.com/i/abcdefghjk"), "ABCDE-FGHJK")
        XCTAssertEqual(code("https://www.yuigui.com/i/ABCDE-FGHJK/"), "ABCDE-FGHJK")
        XCTAssertEqual(code("yui://invite/abcde-fghjk"), "ABCDE-FGHJK")
    }

    func testOtherLinksAreNotInvites() {
        XCTAssertNil(code("https://www.yuigui.com/start"))
        XCTAssertNil(code("https://www.yuigui.com/i/"))
        XCTAssertNil(code("https://evil.example/i/ABCDE-FGHJK"))
        XCTAssertNil(code("http://www.yuigui.com/i/ABCDE-FGHJK"))
        XCTAssertNil(code("yui://agent/7c9e6679-7425-40de-944b-e07fc1f90ae7"))
        XCTAssertNil(code("yui://invite/ab"))
    }

    func testTypedCodes() {
        XCTAssertEqual(Account.normalizedInviteCode(" abcde fghjk "), "ABCDE-FGHJK")
        XCTAssertEqual(Account.normalizedInviteCode("ABCDEFGHJKMN"), "ABCDEFGHJKMN")
        XCTAssertNil(Account.normalizedInviteCode("abc"))
        XCTAssertNil(Account.normalizedInviteCode("-----"))
    }
}
