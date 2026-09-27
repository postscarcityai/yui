import XCTest
@testable import Yui

/// `yui://settings/search` (YUI-142): the button on "Free web searches used"
/// opens Settings at Web search, where a person adds their own Firecrawl key.
@MainActor
final class SettingsLinkTests: XCTestCase {
    func section(_ s: String) -> String? { PushCenter.settingsSection(URL(string: s)!) }

    func testSettingsLinks() {
        XCTAssertEqual(section("yui://settings/search"), "search")
        XCTAssertEqual(section("yui://settings"), "")
        XCTAssertEqual(section("yui://settings/"), "")
        XCTAssertEqual(section("yui://settings/nowhere"), "", "an unknown section opens Settings at the top")
    }

    func testOtherLinksAreNotSettings() {
        XCTAssertNil(section("https://www.yuigui.com/settings/search"))
        XCTAssertNil(section("yui://agent/7c9e6679-7425-40de-944b-e07fc1f90ae7"))
        XCTAssertNil(section("yui://invite/ABCDE-FGHJK"))
    }

    func testOpeningALinkLeavesItForTheChat() {
        let push = PushCenter.shared
        XCTAssertTrue(push.open(URL(string: "yui://settings/search")!))
        XCTAssertEqual(push.pendingSettings, "search")
        XCTAssertNil(push.pendingAgentID)
        push.pendingSettings = nil
    }

    func testFreeSearchesLeftReadsPlain() {
        let left = NativeStatus.Search(used: 12, limit: 50, key: nil)
        XCTAssertEqual(SearchKeyWords.left(left), "Your crew has 38 of 50 free web searches left this month. Add your own Firecrawl key for no limit.")
        let none = NativeStatus.Search(used: 50, limit: 50, key: nil)
        XCTAssertTrue(SearchKeyWords.left(none).hasPrefix("Your 50 free web searches are used up this month."))
    }

    func testStatusDecodesSearch() throws {
        let json = #"{"key":null,"providers":[],"turns":{"used":3,"limit":100},"search":{"used":4,"limit":50,"key":{"hint":"a1b2"}}}"#
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let s = try d.decode(NativeStatus.self, from: Data(json.utf8))
        XCTAssertEqual(s.search, NativeStatus.Search(used: 4, limit: 50, key: .init(hint: "a1b2")))
        let old = try d.decode(NativeStatus.self, from: Data(#"{"key":null,"providers":[],"turns":{"used":0,"limit":100}}"#.utf8))
        XCTAssertNil(old.search, "an older server leaves search out")
    }
}
