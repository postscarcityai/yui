import XCTest
import YuiLines
@testable import Yui

/// YUI-101: what the thread reads on every pass (the rows drawn, who wears a
/// reaction, the pages, talk pages, the newest restyle) is worked out once per
/// change. These check it follows every kind of change: a new row, a row changed
/// in place, a new style, a thread swapped out.
@MainActor
final class ThreadDerivedTests: XCTestCase {
    func testFollowsANewRow() {
        let store = ChatStore(messages: [ChatMessage(id: "a#0", text: "Hi", fromUser: false)])
        XCTAssertEqual(store.screens, [1])
        XCTAssertEqual(store.shown.map(\.id), ["a#0"])
        store.messages.append(ChatMessage(id: "b#0", text: "", fromUser: false, yl: YLScreen(">2 card Plan")))
        XCTAssertEqual(store.screens, [1, 2], "a reply with a page adds the page")
        XCTAssertEqual(store.shown.map(\.id), ["a#0", "b#0"])
        XCTAssertTrue(store.wearsReaction(store.messages[0]))
        XCTAssertTrue(store.wearsReaction(store.messages[1]), "each row's own last bubble")
    }

    func testFollowsARowChangedInPlace() {
        let store = ChatStore(messages: [ChatMessage(id: "a#0", text: "", fromUser: false, yl: YLScreen("say Hi"))])
        XCTAssertEqual(store.screens, [1])
        store.messages[0].yl = YLScreen("say Hi\n>3 list Notes A|B\n>3 talk")
        XCTAssertEqual(store.screens, [1, 3], "a patched reply's page shows")
        XCTAssertEqual(store.talking, [3])
        store.messages[0].yl = YLScreen()
        XCTAssertEqual(store.shown.count, 0, "a reply with nothing left to draw gets no row")
        XCTAssertEqual(store.screens, [1])
    }

    func testFollowsTheStyle() {
        // Whatever a style decides opens on the stage, a style change reads the same
        // as a store made with that style from the start.
        let rows = [ChatMessage(id: "a#0", text: "", fromUser: false, yl: YLScreen(">2 timer 5m Plank\n>3 deck Plan\npage One\nend"))]
        for style in [["screen": "chat"], ["screen": "stage"], ["timer": "stage"], [:]] {
            let store = ChatStore(messages: rows)
            _ = store.screens
            store.style = style
            let fresh = ChatStore(messages: rows)
            fresh.style = style
            XCTAssertEqual(store.screens, fresh.screens, "stale pages after the style became \(style)")
        }
    }

    func testTheRowsLastBubbleWearsItEvenWithCards() {
        let store = ChatStore(messages: [ChatMessage(id: "r#0", text: "Plan?", fromUser: false),
                                         ChatMessage(id: "r#1", text: "", fromUser: false, yl: YLScreen("card Plan")),
                                         ChatMessage(id: "s#0", text: "", fromUser: false, yl: YLScreen("card Only"))])
        XCTAssertTrue(store.wearsReaction(store.messages[0]), "the last text bubble, not the card after it")
        XCTAssertFalse(store.wearsReaction(store.messages[1]))
        XCTAssertTrue(store.wearsReaction(store.messages[2]), "all cards: the last card")
    }

    func testRestyleNewest() {
        let store = ChatStore(messages: [ChatMessage(id: "a#0", text: "", fromUser: false, yl: YLScreen("theme app ocean")),
                                         ChatMessage(id: "b#0", text: "Hi", fromUser: false)])
        XCTAssertEqual(store.restyleNewest, "a#0")
        store.messages.append(ChatMessage(id: "c#0", text: "", fromUser: false, yl: YLScreen("theme app autumn")))
        XCTAssertEqual(store.restyleNewest, "c#0")
    }

    func testMarkdownFromTheCacheIsTheSame() {
        let text = "**Bold** and `code`\n- one\n- two"
        let first = BubbleMarkdown.attributed(text)
        XCTAssertEqual(BubbleMarkdown.attributed(text), first)
        XCTAssertEqual(BubbleMarkdown.plain(text), String(first.characters))
        XCTAssertEqual(BubbleMarkdown.plain("fresh *one*"), "fresh one", "plain before any draw")
    }
}
