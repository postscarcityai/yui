import XCTest
import YuiLines
@testable import Yui

/// YUI-169: several chats with one agent. The pure parts (titles, last lines, times, order and
/// merge, what a delete does), the list's rules, and the store keeping a chat's rows apart from
/// the agent's screens. Spec: yuigui/spec/CHATS.md.
@MainActor
final class ChatsTests: XCTestCase {
    static let basil = MentionFormatTests.agent("a-basil", "Basil", "basil")

    static func chat(_ id: String, _ title: String? = nil, first: Bool = false, at: String, sender: String? = nil,
                     body: String? = nil, unread: Bool = false) -> ChatInfo {
        ChatInfo(id: id, title: title, isFirst: first, lastAt: at, lastSender: sender, lastBody: body,
                 lastMessageAt: body == nil ? nil : at, unread: unread)
    }

    // MARK: Words

    func testTitleFallbacks() {
        XCTAssertEqual(Chats.title(Self.chat("a", "Tuesday's groceries", at: "2026-09-27T10:00:00+00:00"), agent: "Basil"),
                       "Tuesday's groceries")
        XCTAssertEqual(Chats.title(Self.chat("a", first: true, at: "2026-09-27T10:00:00+00:00"), agent: "Basil"), "Hi Basil",
                       "the first chat with no title says hi")
        XCTAssertEqual(Chats.title(Self.chat("a", "  ", first: true, at: "2026-09-27T10:00:00+00:00"), agent: "Basil"), "Hi Basil",
                       "a blank title is no title")
        XCTAssertEqual(Chats.title(Self.chat("a", at: "2026-09-27T10:00:00+00:00"), agent: "Basil"), "New chat",
                       "any other chat with nothing said yet")
    }

    func testLastLine() {
        let said = Self.chat("a", at: "2026-09-27T10:00:00+00:00", sender: "user", body: "how much protein on rest days")
        XCTAssertEqual(Chats.lastLine(said), "You: how much protein on rest days")
        let reply = Self.chat("a", at: "2026-09-27T10:00:00+00:00", sender: "agent", body: "Five dinners, one list.\nTick what you have.")
        XCTAssertEqual(Chats.lastLine(reply), "Five dinners, one list. Tick what you have.", "one quiet line")
        let screen = Self.chat("a", at: "2026-09-27T10:00:00+00:00", sender: "agent", body: "```yui\ncard Plan\n```")
        XCTAssertEqual(Chats.lastLine(screen), "Sent a screen", "a reply that is only a screen")
        let mixed = Self.chat("a", at: "2026-09-27T10:00:00+00:00", sender: "agent", body: "Here you go.\n```yui\ncard Plan\n```")
        XCTAssertEqual(Chats.lastLine(mixed), "Here you go.", "its words, not its screen")
        let tap = Self.chat("a", at: "2026-09-27T10:00:00+00:00", sender: "user", body: "[yui] mood choose pick=Good")
        XCTAssertEqual(Chats.lastLine(tap), "You: Tapped an answer")
        XCTAssertEqual(Chats.lastLine(Self.chat("a", at: "2026-09-27T10:00:00+00:00")), "", "nothing said")
        let long = Self.chat("a", at: "2026-09-27T10:00:00+00:00", sender: "agent", body: String(repeating: "word ", count: 80))
        XCTAssertLessThanOrEqual(Chats.lastLine(long).count, 120)
    }

    func testWhenInPlainWords() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func ago(_ s: TimeInterval) -> String { Chats.when(now.addingTimeInterval(-s), now: now) }
        XCTAssertEqual(ago(20), "now")
        XCTAssertEqual(ago(20 * 60), "20m")
        XCTAssertEqual(ago(2 * 3600), "2h")
        XCTAssertEqual(ago(3 * 86_400), "3d")
        XCTAssertEqual(ago(14 * 86_400), "2w")
        XCTAssertEqual(ago(120 * 86_400), "4mo")
        XCTAssertEqual(ago(-30), "now", "a clock a little ahead never says negative")
    }

    func testAChatSaysWhenItsLastMessageWas() {
        var c = Self.chat("a", at: "2026-09-27T10:00:00+00:00", sender: "user", body: "hi")
        c.lastMessageAt = "2026-09-27T09:00:00+00:00"
        XCTAssertEqual(Chats.when(c, now: YuiTime.date("2026-09-27T11:00:00+00:00")!), "2h", "the message's time, not the chat's")
    }

    func testValidTitle() {
        XCTAssertEqual(Chats.validTitle("  Rest days  "), "Rest days")
        XCTAssertNil(Chats.validTitle("   "), "an empty title is no rename")
        XCTAssertEqual(Chats.validTitle(String(repeating: "a", count: 80))?.count, 60, "1 to 60 characters")
        XCTAssertEqual(Chats.validTitle("x"), "x")
    }

    // MARK: Order and merge

    func testNewestActivityFirst() {
        let list = Chats.ordered([
            Self.chat("old", at: "2026-09-24T10:00:00+00:00"),
            Self.chat("new", at: "2026-09-27T10:00:00+00:00"),
            Self.chat("mid", at: "2026-09-26T10:00:00.5+00:00"),
        ])
        XCTAssertEqual(list.map(\.id), ["new", "mid", "old"])
    }

    func testAReplyInAnOldChatMovesItUp() {
        let list = ChatList()
        list.apply(page: [Self.chat("b", at: "2026-09-27T10:00:00+00:00"), Self.chat("a", at: "2026-09-26T10:00:00+00:00")])
        list.said(in: "a", sender: "agent", body: "Same as training days.", at: "2026-09-27T11:00:00+00:00")
        XCTAssertEqual(list.items.map(\.id), ["a", "b"])
        XCTAssertEqual(list.items[0].lastBody, "Same as training days.")
    }

    func testAShortPageIsTheWholeList() {
        let current = [Self.chat("gone", at: "2026-09-27T10:00:00+00:00"), Self.chat("kept", at: "2026-09-26T10:00:00+00:00")]
        let merged = Chats.merge(current, page: [Self.chat("kept", "Renamed", at: "2026-09-26T10:00:00+00:00")], pageSize: 30)
        XCTAssertEqual(merged.map(\.id), ["kept"], "a chat deleted on another phone goes")
        XCTAssertEqual(merged[0].title, "Renamed", "and a rename shows")
    }

    func testAFullPageKeepsTheOlderChatsAlreadyLoaded() {
        // Three per page. The person scrolled and has "far" loaded; the fresh first page must not drop it.
        let page = [Self.chat("c", at: "2026-09-27T12:00:00+00:00"), Self.chat("b", at: "2026-09-27T11:00:00+00:00"),
                    Self.chat("a", at: "2026-09-27T10:00:00+00:00")]
        let current = page + [Self.chat("far", at: "2026-09-01T10:00:00+00:00"),
                              Self.chat("deleted", at: "2026-09-27T11:30:00+00:00")]
        let merged = Chats.merge(current, page: page, pageSize: 3)
        XCTAssertEqual(merged.map(\.id), ["c", "b", "a", "far"],
                       "older chats stay; one newer than the page's last row and not on it was deleted")
    }

    func testTheNextPageAddsOlderChatsWithoutDoubles() {
        let now = [Self.chat("c", at: "2026-09-27T12:00:00+00:00"), Self.chat("b", at: "2026-09-27T11:00:00+00:00")]
        let more = Chats.append(now, older: [Self.chat("b", at: "2026-09-27T11:00:00+00:00"), Self.chat("a", at: "2026-09-27T10:00:00+00:00")])
        XCTAssertEqual(more.map(\.id), ["c", "b", "a"])
    }

    func testSearchMatchesTitleOrLastLine() {
        let list = [Self.chat("a", "Protein on rest days", at: "2026-09-27T10:00:00+00:00", sender: "agent", body: "About 140 g."),
                    Self.chat("b", "Tuesday's groceries", at: "2026-09-26T10:00:00+00:00", sender: "agent", body: "Five dinners.")]
        XCTAssertEqual(Chats.filter(list, agent: "Basil", query: "PROTEIN").map(\.id), ["a"])
        XCTAssertEqual(Chats.filter(list, agent: "Basil", query: "dinners").map(\.id), ["b"])
        XCTAssertEqual(Chats.filter(list, agent: "Basil", query: "  ").count, 2)
    }

    // MARK: Delete

    func testTheOnlyChatIsClearedNotDeleted() {
        XCTAssertEqual(Chats.deletePlan(saved: 1), .clear)
        XCTAssertEqual(Chats.deletePlan(saved: 2), .delete)
    }

    func testDeletingTheOpenChatOpensTheNextNewest() {
        let list = [Self.chat("a", at: "2026-09-25T10:00:00+00:00"), Self.chat("c", at: "2026-09-27T10:00:00+00:00"),
                    Self.chat("b", at: "2026-09-26T10:00:00+00:00")]
        XCTAssertEqual(Chats.openAfterDeleting("c", open: "c", list: list), "b")
        XCTAssertEqual(Chats.openAfterDeleting("a", open: "c", list: list), "c", "another chat goes: the open one stays open")
        XCTAssertNil(Chats.openAfterDeleting("a", open: "a", list: [list[0]]), "nothing left to open")
    }

    func testTheSheetSaysWhatWillHappen() {
        let d = Chats.sheet(for: .delete, title: "Tuesday's groceries", agent: "Basil")
        XCTAssertEqual(d.question, "Delete \"Tuesday's groceries\"?")
        XCTAssertEqual(d.note, "Its messages go. Basil still remembers what it learned.")
        XCTAssertEqual(d.confirm, "Delete")
        let c = Chats.sheet(for: .clear, title: "Hi Basil", agent: "Basil")
        XCTAssertEqual(c.question, "Clear this chat?")
        XCTAssertEqual(c.confirm, "Clear")
        for text in [d.question, d.note, c.question, c.note] { XCTAssertFalse(text.contains("\u{2014}"), "no em dashes") }
    }

    // MARK: The empty chat

    func testTappingNewChatTwiceGivesTheSameEmptyChat() {
        let list = ChatList()
        list.apply(page: [Self.chat("a", first: true, at: "2026-09-27T10:00:00+00:00")])
        let one = list.startNew()
        let two = list.startNew()
        XCTAssertEqual(one.id, two.id)
        XCTAssertEqual(list.openID, one.id)
        XCTAssertTrue(list.openIsDraft)
        XCTAssertFalse(one.saved)
    }

    func testAnEmptyChatIsNeverListed() {
        let list = ChatList()
        list.apply(page: [Self.chat("a", first: true, at: "2026-09-27T10:00:00+00:00")])
        _ = list.startNew()
        XCTAssertEqual(list.items.map(\.id), ["a"], "nothing is made until you say something")
        XCTAssertEqual(list.savedCount, 1)
    }

    func testTheFirstWordsSaveTheChat() {
        let list = ChatList()
        list.apply(page: [Self.chat("a", first: true, at: "2026-09-27T10:00:00+00:00")])
        let d = list.startNew()
        list.saveDraft(lastBody: "what should I eat before a run")
        XCTAssertFalse(list.openIsDraft)
        XCTAssertEqual(list.items.first?.id, d.id, "it is on top")
        XCTAssertEqual(list.open?.id, d.id)
        XCTAssertEqual(Chats.lastLine(list.items[0]), "You: what should I eat before a run")
    }

    func testTheServersListReplacesTheDraftOnceItHoldsIt() {
        let list = ChatList()
        list.apply(page: [Self.chat("a", first: true, at: "2026-09-27T10:00:00+00:00")])
        let d = list.startNew()
        list.apply(page: [Self.chat(d.id, at: "2026-09-27T11:00:00+00:00"), Self.chat("a", first: true, at: "2026-09-27T10:00:00+00:00")])
        XCTAssertFalse(list.openIsDraft)
        XCTAssertEqual(list.items.map(\.id), [d.id, "a"])
    }

    func testTheDotGoesWhenTheChatIsRead() {
        let list = ChatList()
        list.apply(page: [Self.chat("a", at: "2026-09-27T10:00:00+00:00", sender: "agent", body: "hi", unread: true)])
        list.markSeen("a", at: "2026-09-27T10:00:00+00:00")
        XCTAssertFalse(list.items[0].unread)
        XCTAssertEqual(list.items[0].seenAt, "2026-09-27T10:00:00+00:00")
    }

    func testRenameAndRemove() {
        let list = ChatList()
        list.apply(page: [Self.chat("a", at: "2026-09-27T10:00:00+00:00"), Self.chat("b", at: "2026-09-26T10:00:00+00:00")])
        list.rename("a", to: "Rest days")
        XCTAssertEqual(list.items[0].title, "Rest days")
        list.remove("a")
        XCTAssertEqual(list.items.map(\.id), ["b"])
    }

    // MARK: The list from the server

    func testTheListDecodesFromTheViewsColumns() throws {
        let json = """
        [{"id":"3F2A0000-0000-4000-8000-000000000001","user_id":"u","agent_id":"a","title":null,"titled_by":"auto",
          "is_first":true,"last_at":"2026-09-27T10:00:00.5+00:00","seen_at":"2026-09-27T09:00:00+00:00",
          "created_at":"2026-09-01T10:00:00+00:00","last_sender":"agent","last_body":"Logged.",
          "last_message_at":"2026-09-27T10:00:00.5+00:00","unread":true}]
        """
        let chats = try JSONDecoder().decode([ChatInfo].self, from: Data(json.utf8))
        XCTAssertEqual(chats.count, 1)
        XCTAssertEqual(chats[0].id, "3f2a0000-0000-4000-8000-000000000001", "ids are lowercase, as the rest of the app reads them")
        XCTAssertTrue(chats[0].isFirst)
        XCTAssertTrue(chats[0].unread)
        XCTAssertTrue(chats[0].saved)
        XCTAssertEqual(Chats.title(chats[0], agent: "Basil"), "Hi Basil")
    }

    func testServerRefusalsAreNamed() {
        XCTAssertEqual(ChatError(message: "update_needed"), .updateNeeded)
        XCTAssertEqual(ChatError(message: "limit_reached"), .limitReached)
        XCTAssertEqual(ChatError(message: "last_chat"), .lastChat)
        XCTAssertEqual(ChatError(message: "chat_not_found"), .notFound)
        XCTAssertEqual(YuiRelay.refusal(Data(#"{"code":"PT403","message":"limit_reached","details":"yui_chats"}"#.utf8)), .limitReached)
        XCTAssertNil(YuiRelay.refusal(Data(#"{"message":"permission denied"}"#.utf8)), "an error we do not know is not a chat error")
        XCTAssertNil(YuiRelay.refusal(Data("nope".utf8)))
        XCTAssertTrue(ChatError.updateNeeded.spoken.contains("Update"))
        XCTAssertTrue(ChatError.limitReached.spoken.contains("full"))
        for e in [ChatError.updateNeeded, .limitReached, .lastChat, .notFound, .other("x")] {
            XCTAssertFalse(e.spoken.contains("\u{2014}"))
            XCTAssertFalse(e.spoken.contains("limit_reached") || e.spoken.contains("update_needed"), "no developer words")
        }
    }

    // MARK: A thread is one chat

    func testAThreadReadsOneChatsRows() {
        func names(_ items: [URLQueryItem]) -> [String: String] {
            Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        }
        let chat = names(ThreadClient.fetchItems(agentID: "agent-1", chatID: "chat-9", since: nil))
        XCTAssertEqual(chat["agent_id"], "eq.agent-1")
        XCTAssertEqual(chat["chat_id"], "eq.chat-9", "the rows of that chat only")
        XCTAssertEqual(chat["limit"], "100")
        let agent = names(ThreadClient.fetchItems(agentID: "agent-1", chatID: nil, since: "2026-09-27T10:00:00+00:00"))
        XCTAssertNil(agent["chat_id"], "a server with no chats reads the agent's thread as before")
        XCTAssertEqual(agent["created_at"], "gt.2026-09-27T10:00:00+00:00")
    }

    func testTheScreenPatternMatchesTheAgentsLinesAndNotTheChat() throws {
        // The server side is a POSIX regex; NSRegularExpression reads this one the same way.
        let re = try NSRegularExpression(pattern: ThreadClient.scopedPattern)
        func hit(_ body: String) -> Bool { re.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) != nil }
        XCTAssertTrue(hit("```yui\n>2 card Plan\n```"), "a screen")
        XCTAssertTrue(hit(">3 list Notes A|B"))
        XCTAssertTrue(hit("say Saved.\nsave workout"), "a save")
        XCTAssertTrue(hit("```yui\nmenu review@dana \"Invite Dana?\"\n```"), "a drawer line")
        XCTAssertTrue(hit("```yui\n~stat +1\n```"), "a patch")
        XCTAssertFalse(hit("Just words, and a > sign in them."))
        XCTAssertFalse(hit("```yui\ncard Plan\nchoose Which one?\n```"), "a chat reply with no screen or save is the chat's")
    }

    func testTheAgentsScreensShowInEveryChatButNotInItsThread() {
        let store = ChatStore(messages: [ChatMessage(id: "m#0", text: "Hello from this chat", fromUser: false)])
        XCTAssertEqual(store.screens, [1])
        // A row from another chat that drew screen 2.
        store.addScoped(ThreadRow(id: "S1", sender: "agent", body: "```yui\n>2 card \"Leg day\"\n```", kind: "text", meta: nil,
                                  createdAt: "2026-09-27T10:00:00+00:00"))
        XCTAssertEqual(store.screens, [1, 2], "the screen is the agent's")
        XCTAssertEqual(store.onPage(2).count, 1)
        XCTAssertEqual(store.shown.map(\.id), ["m#0"], "and the thread stays this chat's")
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.pageTitle(2), "Leg day")
    }

    func testAnotherChatsQuestionIsNotWaitingOnYouHere() {
        let store = ChatStore()
        store.addScoped(ThreadRow(id: "S1", sender: "agent", body: "```yui\nchoose@plan \"Which plan?\" A|B\n```", kind: "text",
                                  meta: nil, createdAt: "2026-09-27T10:00:00+00:00"))
        XCTAssertTrue(store.awaitingYou.isEmpty, "a question on the chat page belongs to that chat")
        store.addScoped(ThreadRow(id: "S2", sender: "agent", body: "```yui\n>2 choose@pick \"Which day?\" Mon|Tue\n```", kind: "text",
                                  meta: nil, createdAt: "2026-09-27T10:01:00+00:00"))
        XCTAssertEqual(store.awaitingYou.map(\.ask.ylID), ["pick"], "a question on the agent's screen waits in every chat")
    }

    func testAScreenPatchFromAnotherChatReachesTheScreen() {
        let store = ChatStore()
        store.addScoped(ThreadRow(id: "S1", sender: "agent", body: "```yui\n>2\nstat@mvp 60% \"MVP shipped\"\n```", kind: "text", meta: nil,
                                  createdAt: "2026-09-27T10:00:00+00:00"))
        store.addScoped(ThreadRow(id: "S2", sender: "agent", body: "```yui\n~mvp 64%\n```", kind: "text", meta: nil,
                                  createdAt: "2026-09-27T10:05:00+00:00"))
        let stat = store.onPage(2).compactMap(\.yl).flatMap(\.components).first { $0.ylID == "mvp" }
        XCTAssertEqual(stat?.props["value"], .number(64))
    }

    // MARK: The store's chats (the demo account, no server)

    func testDemoHasOneLocalChatAndNewChatIsLocalAndEmpty() {
        let store = ChatStore()
        store.demo(Self.basil)
        XCTAssertEqual(store.chats.items.count, 1)
        XCTAssertEqual(store.chatTitle, "Hi Basil")
        let first = store.chatID
        store.newChat()
        XCTAssertEqual(store.chatID, first, "already in an empty chat: that is the new chat")
        store.messages.append(ChatMessage(text: "Log two eggs", fromUser: true))
        store.newChat()
        XCTAssertNotEqual(store.chatID, first)
        XCTAssertEqual(store.chatTitle, "New chat")
        XCTAssertTrue(store.chats.openIsDraft)
        XCTAssertEqual(store.chats.items.count, 1, "the empty chat is not in the list")
        let draft = store.chatID
        store.newChat()
        XCTAssertEqual(store.chatID, draft, "twice is the same empty chat")
        XCTAssertTrue(store.messages.isEmpty)
    }

    func testSayingSomethingInANewDemoChatSavesIt() {
        let store = ChatStore()
        store.demo(Self.basil)
        store.messages.append(ChatMessage(text: "Log two eggs", fromUser: true))
        let first = store.chatID!
        store.newChat()
        XCTAssertEqual(store.chats.items.count, 1, "nothing is made until you say something")
        store.messages.append(ChatMessage(text: "Plan dinners", fromUser: true))
        XCTAssertEqual(store.chats.items.count, 2)
        XCTAssertFalse(store.chats.openIsDraft)
        // Back to the first chat and again: what was said stays with its chat for the session.
        let second = store.chatID!
        store.openChat(first)
        XCTAssertEqual(store.messages.map(\.text), ["Log two eggs"])
        store.openChat(second)
        XCTAssertEqual(store.messages.map(\.text), ["Plan dinners"])
    }

    func testLeavingAnEmptyChatSavesNothing() {
        let store = ChatStore()
        store.demo(Self.basil)
        store.messages.append(ChatMessage(text: "Log two eggs", fromUser: true))
        let first = store.chatID!
        store.newChat()
        XCTAssertNotEqual(store.chatID, first)
        store.openChat(first)
        XCTAssertEqual(store.chats.items.count, 1, "an empty chat left behind is not saved")
        XCTAssertEqual(store.chatID, first)
    }

    func testDeletingTheOpenDemoChatOpensTheNextAndTheLastOneIsCleared() async {
        let store = ChatStore()
        store.demo(Self.basil)
        store.messages.append(ChatMessage(text: "Log two eggs", fromUser: true))
        let first = store.chatID!
        store.newChat()
        store.messages.append(ChatMessage(text: "Plan dinners", fromUser: true))
        let second = store.chatID!
        XCTAssertEqual(store.deletePlan, .delete)
        await store.deleteChat(second)
        XCTAssertEqual(store.chatID, first, "the next newest opens")
        XCTAssertEqual(store.chats.items.map(\.id), [first])
        // The only chat: clear, not delete.
        store.messages.append(ChatMessage(text: "Hi", fromUser: true))
        XCTAssertEqual(store.deletePlan, .clear)
        await store.deleteChat(first)
        XCTAssertEqual(store.chats.items.map(\.id), [first], "the chat stays")
        XCTAssertTrue(store.messages.isEmpty, "with no messages")
    }

    func testRenameShowsAtOnceAndTooLongIsCut() {
        let store = ChatStore()
        store.demo(Self.basil)
        store.renameChat(store.chatID!, to: "  Rest day protein  ")
        XCTAssertEqual(store.chatTitle, "Rest day protein")
        store.renameChat(store.chatID!, to: "   ")
        XCTAssertEqual(store.chatTitle, "Rest day protein", "an empty title changes nothing")
    }

    func testAPushOpensTheChatItCameFrom() {
        let store = ChatStore()
        store.demo(Self.basil)
        store.openPushed("Abc-123")
        XCTAssertEqual(store.chatID, "abc-123", "lowercase, as the server sends ids")
    }

    func testSwitchingAgentsKeepsNoChatOfTheOther() {
        let store = ChatStore()
        store.demo(Self.basil)
        let a = store.chatID
        store.demo(MentionFormatTests.coach)
        XCTAssertNotEqual(store.chatID, a)
        XCTAssertEqual(store.chats.items.count, 1)
    }

    // MARK: The outbox

    func testAnOutboxItemFromBeforeChatsStillReads() throws {
        let old = """
        {"id":"r1","userID":"u","agentID":"a","body":"hi","kind":"text","queuedAt":800000000}
        """
        let item = try JSONDecoder().decode(Outbox.Item.self, from: Data(old.utf8))
        XCTAssertNil(item.chatID, "it lands in the newest chat")
        XCTAssertNil(item.createChat)
    }

    func testTheOutboxHoldsItemsForOneChatOnly() {
        let box = Outbox(file: FileManager.default.temporaryDirectory.appending(path: "chats-outbox-\(UUID().uuidString).json"))
        box.add(.init(id: "1", userID: "u", agentID: "a", body: "in one", kind: "text", meta: nil, queuedAt: .now, chatID: "c1"))
        box.add(.init(id: "2", userID: "u", agentID: "a", body: "in two", kind: "text", meta: nil, queuedAt: .now, chatID: "c2"))
        box.add(.init(id: "3", userID: "u", agentID: "a", body: "from before chats", kind: "text", meta: nil, queuedAt: .now))
        XCTAssertEqual(box.pending(agentID: "a", chatID: "c1").map(\.id), ["1", "3"])
        XCTAssertEqual(box.pending(agentID: "a", chatID: "c2").map(\.id), ["2", "3"])
        XCTAssertEqual(box.pending(agentID: "a").count, 3)
    }
}
