import XCTest
@testable import Yui

/// A screen beside the chat is named for what is on it (Chris, Oct 5: "Screen 2" means nothing).
@MainActor
final class ScreenNameTests: XCTestCase {
    func testSavedNameWins() {
        XCTAssertEqual(ScreenName.pick(saved: "this-week", titles: ["Workouts this week"], kinds: ["stat"]), "This week")
    }

    func testFirstTitleWhenNothingSaved() {
        XCTAssertEqual(ScreenName.pick(saved: nil, titles: ["", "Workouts"], kinds: ["stat", "list"]), "Workouts")
        XCTAssertEqual(ScreenName.pick(saved: "  ", titles: ["Leg day"], kinds: []), "Leg day")
    }

    func testAWordForWhatIsOnItWhenNoTitle() {
        XCTAssertEqual(ScreenName.pick(saved: nil, titles: [], kinds: ["timer"]), "Timer")
        XCTAssertEqual(ScreenName.pick(saved: nil, titles: [], kinds: ["nope", "list"]), "List")
        XCTAssertEqual(ScreenName.pick(saved: nil, titles: [], kinds: []), "Page")
    }

    func testNeverScreenNumberAndLongNamesCut() {
        let long = ScreenName.pick(saved: nil, titles: ["A very long title for a tab in the row"], kinds: [])
        XCTAssertLessThanOrEqual(long.count, ScreenName.maxLength)
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertFalse(ScreenName.pick(saved: nil, titles: [], kinds: ["x"]).hasPrefix("Screen"))
    }

    func testStoreNamesPagesFromTheirContent() {
        let store = ChatStore(messages: [])
        for (i, body) in ["```yui\n>2 stat 1 Workouts\n>2 list \"This week\" A|B\n```",
                          "```yui\n>3 timer 5m\n```",
                          "```yui\n>4 list Notes A|B\n>4 save groceries\n```"].enumerated() {
            store.addScoped(ThreadRow(id: "S\(i)", sender: "agent", body: body, kind: "text", meta: nil,
                                      createdAt: "2026-10-05T10:0\(i):00+00:00"))
        }
        XCTAssertEqual(store.pageTitle(2), "Workouts")
        XCTAssertEqual(store.pageTitle(3), "Timer")
        XCTAssertEqual(store.pageTitle(4), "Groceries")
        for n in store.screens.dropFirst() { XCTAssertFalse(store.pageTitle(n).hasPrefix("Screen")) }
    }
}
