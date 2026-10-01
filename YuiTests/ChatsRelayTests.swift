import XCTest
import YuiLines
@testable import Yui

/// YUI-169 against the real code path with a stand-in relay: PostgREST as Yui's server answers it
/// (the chat list view, chats, messages, the refusals), behind a URLProtocol. New chat writes
/// nothing until something is said, then the chat and the message go in that order with the chat's
/// id; a refused chat gives the words back; delete and clear hit the right rows; rename and
/// "seen" are saved; the screens of the agent's other chats reach this one.
final class FakeRelay: URLProtocol, @unchecked Sendable {
    struct Call { let method: String; let path: String; let query: [String: String]; let body: [String: Any] }
    nonisolated(unsafe) static var calls: [Call] = []
    nonisolated(unsafe) static var chats: [[String: Any]] = []
    nonisolated(unsafe) static var messages: [[String: Any]] = []
    /// A chat insert is refused with this PostgREST message.
    nonisolated(unsafe) static var refuseChat: String?
    private static let lock = NSLock()

    static func reset(chats: [[String: Any]], messages: [[String: Any]]) {
        lock.lock(); defer { lock.unlock() }
        calls = []; self.chats = chats; self.messages = messages; refuseChat = nil
    }
    static func log() -> [Call] { lock.lock(); defer { lock.unlock() }; return calls }
    static func snapshot(_ f: () -> Void) { lock.lock(); f(); lock.unlock() }

    static func chat(_ id: String, first: Bool = false, at: String, title: String? = nil) -> [String: Any] {
        ["id": id, "user_id": "u1", "agent_id": "a-basil", "title": (title as Any?) ?? NSNull(), "titled_by": "auto", "is_first": first,
         "last_at": at, "seen_at": at, "created_at": at]
    }
    static func message(_ id: String, chat: String, sender: String = "user", body: String, at: String,
                        meta: [String: Any]? = nil) -> [String: Any] {
        ["id": id, "chat_id": chat, "agent_id": "a-basil", "sender": sender, "body": body, "kind": "text",
         "meta": (meta as Any?) ?? NSNull(), "created_at": at]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let path = url.lastPathComponent
        var query: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        var body: [String: Any] = [:]
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            stream.close()
            body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        } else if let data = request.httpBody {
            body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        let method = request.httpMethod ?? "GET"
        Self.lock.lock()
        Self.calls.append(Call(method: method, path: path, query: query, body: body))
        let (status, payload) = Self.answer(method: method, path: path, query: query, body: body)
        Self.lock.unlock()
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("[]".utf8)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func eq(_ v: String?) -> String? { v.flatMap { $0.hasPrefix("eq.") ? String($0.dropFirst(3)) : nil } }

    private static func answer(method: String, path: String, query: [String: String], body: [String: Any]) -> (Int, Any) {
        switch (method, path) {
        case ("GET", "yui_chat_list"):
            var rows = chats.sorted { ($0["last_at"] as! String) > ($1["last_at"] as! String) }
            let offset = Int(query["offset"] ?? "0") ?? 0, limit = Int(query["limit"] ?? "30") ?? 30
            rows = Array(rows.dropFirst(offset).prefix(limit))
            return (200, rows.map { c -> [String: Any] in
                let id = c["id"] as! String
                let last = messages.filter { $0["chat_id"] as? String == id }.max { ($0["created_at"] as! String) < ($1["created_at"] as! String) }
                var out = c
                out["last_sender"] = last?["sender"] ?? NSNull()
                out["last_body"] = last?["body"] ?? NSNull()
                out["last_message_at"] = last?["created_at"] ?? NSNull()
                out["unread"] = (last?["sender"] as? String == "agent") && ((last?["created_at"] as? String ?? "") > (c["seen_at"] as? String ?? ""))
                return out
            })
        case ("GET", "yui_messages"):
            if query["body"] != nil {  // the agent's screens said in other chats
                let other = eq(query["chat_id"].map { $0.replacingOccurrences(of: "neq.", with: "eq.") })
                return (200, messages.filter { ($0["chat_id"] as? String) != other && ($0["sender"] as? String) == "agent"
                    && (($0["body"] as? String) ?? "").contains(">2") }.sorted { ($0["created_at"] as! String) < ($1["created_at"] as! String) })
            }
            var rows = messages
            if let chat = eq(query["chat_id"]) { rows = rows.filter { $0["chat_id"] as? String == chat } }
            if let since = query["created_at"]?.replacingOccurrences(of: "gt.", with: "") { rows = rows.filter { ($0["created_at"] as! String) > since } }
            rows.sort { ($0["created_at"] as! String) < ($1["created_at"] as! String) }
            if query["order"] == "created_at.desc" { rows.reverse() }
            return (200, rows)
        case ("POST", "yui_chats"):
            if let refuse = refuseChat { return (403, ["code": "PT403", "message": refuse]) }
            var c = chat(body["id"] as! String, first: false, at: "2026-09-28T12:00:00+00:00")
            c["agent_id"] = body["agent_id"]
            chats.append(c)
            return (201, [])
        case ("POST", "yui_messages"):
            var m = body
            m["created_at"] = "2026-09-28T12:00:01+00:00"
            messages.append(m)
            if let id = body["chat_id"] as? String, let i = chats.firstIndex(where: { $0["id"] as? String == id }) {
                chats[i]["last_at"] = "2026-09-28T12:00:01+00:00"
            }
            return (201, [])
        case ("DELETE", "yui_chats"):
            guard let id = eq(query["id"]) else { return (400, ["message": "bad"]) }
            if chats.count == 1 { return (400, ["code": "23514", "message": "last_chat"]) }
            chats.removeAll { $0["id"] as? String == id }
            messages.removeAll { $0["chat_id"] as? String == id }
            return (204, [])
        case ("DELETE", "yui_messages"):
            guard let id = eq(query["chat_id"]) else { return (400, ["message": "bad"]) }
            messages.removeAll { $0["chat_id"] as? String == id }
            return (204, [])
        case ("PATCH", "yui_chats"):
            guard let id = eq(query["id"]), let i = chats.firstIndex(where: { $0["id"] as? String == id }) else { return (404, ["message": "none"]) }
            for (k, v) in body { chats[i][k] = v }
            return (204, [])
        default:
            return (200, [])
        }
    }
}

@MainActor
final class ChatsRelayTests: XCTestCase {
    static let basil = MentionFormatTests.agent("a-basil", "Basil", "basil")
    var account: Account!

    override func setUp() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeRelay.self]
        YuiRelay.session = URLSession(configuration: config)
        account = Account.signedIn(userID: "u1")
        Outbox.shared.clear()
        Outbox.shared.start(account: account)
        FakeRelay.reset(chats: [
            FakeRelay.chat("c-hi", first: true, at: "2026-09-25T10:00:00+00:00"),
            FakeRelay.chat("c-two", at: "2026-09-27T10:00:00+00:00", title: "Protein on rest days"),
        ], messages: [
            FakeRelay.message("m1", chat: "c-hi", sender: "agent", body: "Hi. I'm Basil.", at: "2026-09-25T10:00:00+00:00"),
            FakeRelay.message("m2", chat: "c-two", body: "How much protein on rest days?", at: "2026-09-27T09:59:00+00:00"),
            FakeRelay.message("m3", chat: "c-two", sender: "agent", body: "About 140 g.", at: "2026-09-27T10:00:00+00:00"),
        ])
    }

    override func tearDown() async throws {
        Outbox.shared.clear()
        YuiRelay.session = .shared
    }

    /// Waits up to `seconds` for `ok`.
    private func until(_ what: String, seconds: Double = 8, _ ok: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !ok(), Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(ok(), "timed out: \(what)")
    }

    private func attach() async -> ChatStore {
        let store = ChatStore()
        store.attach(Self.basil, account: account)
        await until("the thread opened on the newest chat") { store.chatID == "c-two" && store.loaded && !store.messages.isEmpty }
        return store
    }

    func testTheThreadIsTheNewestChatsRowsOnly() async {
        let store = await attach()
        XCTAssertEqual(store.messages.map(\.text), ["How much protein on rest days?", "About 140 g."])
        XCTAssertEqual(store.chats.items.map(\.id), ["c-two", "c-hi"], "newest activity first")
        XCTAssertEqual(store.chatTitle, "Protein on rest days")
        XCTAssertTrue(FakeRelay.log().contains { $0.path == "yui_messages" && $0.query["chat_id"] == "eq.c-two" },
                      "the read names the chat")
        // The key vault's control read (YUI-34) is the agent's, not a chat's rows.
        XCTAssertFalse(FakeRelay.log().contains { $0.path == "yui_messages" && $0.method == "GET" && $0.query["chat_id"] == nil && $0.query["body"] == nil && $0.query["kind"] != "eq.control" },
                       "no read of the agent's whole thread")
    }

    func testNewChatWritesNothingUntilYouSaySomething() async {
        let store = await attach()
        store.newChat()
        XCTAssertTrue(store.chats.openIsDraft)
        XCTAssertEqual(store.chatTitle, "New chat")
        store.newChat()  // twice: the same one
        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(FakeRelay.log().contains { $0.method == "POST" }, "an empty chat is never written")
        XCTAssertEqual(FakeRelay.chats.count, 2)
        let draft = store.chatID!

        XCTAssertTrue(store.send("Plan dinners for the week"))
        await until("the chat and the message reached the relay") {
            FakeRelay.log().contains { $0.method == "POST" && $0.path == "yui_messages" }
        }
        let posts = FakeRelay.log().filter { $0.method == "POST" }.map(\.path)
        XCTAssertEqual(posts, ["yui_chats", "yui_messages"], "the chat first, then the words")
        let chatBody = FakeRelay.log().first { $0.path == "yui_chats" && $0.method == "POST" }!.body
        XCTAssertEqual(chatBody["id"] as? String, draft)
        XCTAssertEqual(chatBody["agent_id"] as? String, "a-basil")
        XCTAssertEqual(chatBody["user_id"] as? String, "u1")
        XCTAssertEqual(Set(chatBody.keys), ["id", "user_id", "agent_id"], "only what yui_user may insert")
        let row = FakeRelay.log().first { $0.path == "yui_messages" && $0.method == "POST" }!.body
        XCTAssertEqual(row["chat_id"] as? String, draft, "the message carries its chat")
        XCTAssertEqual(row["body"] as? String, "Plan dinners for the week")
        XCTAssertFalse(store.chats.openIsDraft)
        XCTAssertEqual(store.chats.items.first?.id, draft, "it is on top of the list")
    }

    func testAChatTheServerRefusesGivesTheWordsBack() async {
        let store = await attach()
        FakeRelay.snapshot { FakeRelay.refuseChat = "limit_reached" }
        store.newChat()
        XCTAssertTrue(store.send("Plan dinners for the week"))
        await until("the refusal came back") { store.refusal != nil }
        XCTAssertEqual(store.refusal?.text, "Plan dinners for the week")
        XCTAssertEqual(store.refusal?.note, ChatError.limitReached.spoken)
        XCTAssertTrue(store.messages.isEmpty, "the bubble is taken back")
        XCTAssertFalse(store.waiting)
        XCTAssertFalse(FakeRelay.log().contains { $0.method == "POST" && $0.path == "yui_messages" }, "no message without its chat")
        XCTAssertTrue(store.chats.openIsDraft, "still an empty chat, not saved")

        FakeRelay.snapshot { FakeRelay.refuseChat = "update_needed" }
        store.clearRefusal()
        XCTAssertTrue(store.send("Try again"))
        await until("update needed came back") { store.refusal != nil }
        XCTAssertEqual(store.refusal?.note, ChatError.updateNeeded.spoken)
    }

    func testMessagesInAChatCarryItsId() async {
        let store = await attach()
        XCTAssertTrue(store.send("And on training days?"))
        await until("posted") { FakeRelay.log().contains { $0.method == "POST" && $0.path == "yui_messages" } }
        let row = FakeRelay.log().first { $0.path == "yui_messages" && $0.method == "POST" }!.body
        XCTAssertEqual(row["chat_id"] as? String, "c-two")
        XCTAssertFalse(FakeRelay.log().contains { $0.method == "POST" && $0.path == "yui_chats" }, "an old chat is not made again")
    }

    func testDeleteRemovesTheChatAndOpensTheNextNewest() async {
        let store = await attach()
        await store.deleteChat("c-two")
        XCTAssertTrue(FakeRelay.log().contains { $0.method == "DELETE" && $0.path == "yui_chats" && $0.query["id"] == "eq.c-two" })
        XCTAssertEqual(store.chatID, "c-hi", "the next newest opens")
        XCTAssertEqual(store.chats.items.map(\.id), ["c-hi"])
        await until("the thread is the other chat's") { store.messages.map(\.text) == ["Hi. I'm Basil."] }
    }

    func testTheOnlyChatIsClearedByDeletingItsMessages() async {
        let store = await attach()
        await store.deleteChat("c-hi")  // another chat, not the open one: it goes
        XCTAssertEqual(store.chatID, "c-two")
        XCTAssertEqual(store.deletePlan, .clear)
        await store.deleteChat("c-two")
        let calls = FakeRelay.log().filter { $0.method == "DELETE" }
        XCTAssertEqual(calls.last?.path, "yui_messages")
        XCTAssertEqual(calls.last?.query["chat_id"], "eq.c-two")
        XCTAssertEqual(calls.filter { $0.path == "yui_chats" }.count, 1, "the chat itself is never deleted")
        XCTAssertEqual(store.chatID, "c-two")
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertEqual(store.chats.items.map(\.id), ["c-two"])
    }

    func testRenameIsSaved() async {
        let store = await attach()
        store.renameChat("c-two", to: "  Rest days  ")
        await until("patched") { FakeRelay.log().contains { $0.method == "PATCH" && $0.path == "yui_chats" } }
        let patch = FakeRelay.log().first { $0.method == "PATCH" }!
        XCTAssertEqual(patch.query["id"], "eq.c-two")
        XCTAssertEqual(patch.body["title"] as? String, "Rest days")
        XCTAssertEqual(Set(patch.body.keys), ["title"], "only the title")
    }

    func testAnAgentReplyReadInTheOpenChatClearsItsDotEverywhere() async {
        FakeRelay.snapshot {
            FakeRelay.chats[1]["seen_at"] = "2026-09-27T09:00:00+00:00"  // "About 140 g." is newer: unread
        }
        let store = await attach()
        await until("seen_at reported") { FakeRelay.log().contains { $0.method == "PATCH" && $0.body["seen_at"] != nil } }
        let patch = FakeRelay.log().first { $0.method == "PATCH" && $0.body["seen_at"] != nil }!
        XCTAssertEqual(patch.query["id"], "eq.c-two")
        XCTAssertEqual(patch.body["seen_at"] as? String, "2026-09-27T10:00:00+00:00", "the newest agent row's own time")
        XCTAssertFalse(store.chats.items.first { $0.id == "c-two" }!.unread)
    }

    func testAnUnreadChatShowsItsDotInTheList() async {
        FakeRelay.snapshot {
            FakeRelay.chats[0]["seen_at"] = "2026-09-20T09:00:00+00:00"  // "Hi. I'm Basil." is newer: unread
        }
        let store = await attach()
        XCTAssertTrue(store.chats.items.first { $0.id == "c-hi" }!.unread)
        XCTAssertFalse(store.chats.items.first { $0.id == "c-two" }!.unread)
    }

    func testTheAgentsScreensFromAnotherChatReachThisOne() async {
        FakeRelay.snapshot {
            FakeRelay.messages.append(FakeRelay.message("m0", chat: "c-hi", sender: "agent", body: "```yui\n>2 card \"Leg day\"\n```",
                                                        at: "2026-09-25T10:01:00+00:00"))
        }
        let store = await attach()
        await until("the screen arrived") { store.screens == [1, 2] }
        XCTAssertEqual(store.pageTitle(2), "Leg day")
        XCTAssertEqual(store.messages.map(\.text), ["How much protein on rest days?", "About 140 g."], "the thread is still this chat's")
    }

    func testAPushNamesTheChatAndItOpens() async {
        let store = ChatStore()
        store.wantedChat = "c-hi"
        store.attach(Self.basil, account: account)
        await until("opened on the pushed chat") { store.chatID == "c-hi" && store.loaded }
        await until("the chat list arrived") { store.chats.savedCount > 1 }  // the title reads the list, which lands after the chat opens
        XCTAssertEqual(store.chatTitle, "Earlier", "YUI-254: with a second chat saved, the untitled first one is Earlier")
    }

    /// Build 332: New chat (or a push) before the first list answer left chatID set, so the list
    /// was dropped and the drawer showed New chat with nothing under it, for good.
    func testTheListStillLoadsWhenAChatIsOpenedBeforeItArrives() async {
        let store = ChatStore()
        store.attach(Self.basil, account: account)
        store.newChat()
        XCTAssertTrue(store.chats.openIsDraft)
        await until("the list is in the drawer") { store.chats.loaded }
        XCTAssertEqual(store.chats.items.map(\.id), ["c-two", "c-hi"])
        XCTAssertTrue(store.chats.openIsDraft, "the chat you opened stays open")
        store.openChat("c-hi")
        XCTAssertEqual(store.chatID, "c-hi", "and a past chat opens from the list")
    }

    func testOlderChatsLoadAsTheListScrolls() async {
        var many: [[String: Any]] = []
        for i in 0..<35 {
            many.append(FakeRelay.chat("c\(String(format: "%02d", i))", first: i == 0, at: "2026-08-01T10:\(String(format: "%02d", i)):00+00:00"))
        }
        FakeRelay.snapshot { FakeRelay.chats = many; FakeRelay.messages = [] }
        let store = ChatStore()
        store.attach(Self.basil, account: account)
        await until("the first page") { store.chats.loaded }
        XCTAssertEqual(store.chats.items.count, 30, "the 30 newest")
        XCTAssertTrue(store.chats.more)
        await store.loadMoreChats()
        XCTAssertEqual(store.chats.items.count, 35)
        XCTAssertFalse(store.chats.more)
    }
}
