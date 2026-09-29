import Foundation
import Observation

// Several chats with one agent (YUI-169, spec yuigui/spec/CHATS.md). A chat is one
// conversation: its own messages and a title. Screens, the shelf, the drawer's rows
// and memory stay the agent's. The pure parts (titles, last lines, times, order,
// merge, what a delete does) live in `Chats`, so the tests need no network.

/// One row of `yui_chat_list`: a chat, the last line said in it, whether the agent
/// has said something the person has not looked at.
struct ChatInfo: Identifiable, Equatable, Decodable, Sendable {
    let id: String
    var title: String?
    var isFirst = false
    var lastAt: String
    var seenAt: String?
    var lastSender: String?
    var lastBody: String?
    var lastMessageAt: String?
    var unread = false
    /// False for a chat made on this phone that nothing has been said in yet: it is
    /// not on the server, and it never shows in the list.
    var saved = true

    enum CodingKeys: String, CodingKey {
        case id, title, unread
        case isFirst = "is_first", lastAt = "last_at", seenAt = "seen_at"
        case lastSender = "last_sender", lastBody = "last_body", lastMessageAt = "last_message_at"
    }

    init(id: String, title: String? = nil, isFirst: Bool = false, lastAt: String, seenAt: String? = nil,
         lastSender: String? = nil, lastBody: String? = nil, lastMessageAt: String? = nil,
         unread: Bool = false, saved: Bool = true) {
        self.id = id
        self.title = title
        self.isFirst = isFirst
        self.lastAt = lastAt
        self.seenAt = seenAt
        self.lastSender = lastSender
        self.lastBody = lastBody
        self.lastMessageAt = lastMessageAt
        self.unread = unread
        self.saved = saved
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id).lowercased()
        title = try c.decodeIfPresent(String.self, forKey: .title)
        isFirst = try c.decodeIfPresent(Bool.self, forKey: .isFirst) ?? false
        lastAt = try c.decodeIfPresent(String.self, forKey: .lastAt) ?? ""
        seenAt = try c.decodeIfPresent(String.self, forKey: .seenAt)
        lastSender = try c.decodeIfPresent(String.self, forKey: .lastSender)
        lastBody = try c.decodeIfPresent(String.self, forKey: .lastBody)
        lastMessageAt = try c.decodeIfPresent(String.self, forKey: .lastMessageAt)
        unread = try c.decodeIfPresent(Bool.self, forKey: .unread) ?? false
    }
}

/// What Yui's server can refuse a chat with (PostgREST `message`).
enum ChatError: Error, Equatable {
    /// `update_needed`: this build is below `chats_min_build`.
    case updateNeeded
    /// `limit_reached`: the agent already holds `chats_per_agent`.
    case limitReached
    /// `last_chat`: an agent's only chat cannot be deleted.
    case lastChat
    /// `chat_not_found`.
    case notFound
    case other(String)

    init(message: String) {
        switch message {
        case "update_needed": self = .updateNeeded
        case "limit_reached": self = .limitReached
        case "last_chat": self = .lastChat
        case "chat_not_found": self = .notFound
        default: self = .other(message)
        }
    }

    /// Plain words for the person, nil when nothing useful can be said.
    var spoken: String {
        switch self {
        case .updateNeeded: "New chats need the latest Yui. Update the app to start one."
        case .limitReached: "This agent's chat list is full. Delete one to start another."
        case .lastChat: "That is the only chat with this agent, so it can only be cleared."
        case .notFound: "That chat is gone."
        case .other: "Couldn't do that right now. Try again in a moment."
        }
    }
}

/// What a delete does for a chat in a list of this many saved chats.
enum ChatDelete: Equatable {
    /// The chat goes with its messages.
    case delete
    /// The agent's only chat: it stays, its messages go.
    case clear
}

enum Chats {
    /// How many chats the list asks for at a time.
    static let pageSize = 30
    /// The list gets a search field past this many chats.
    static let searchAfter = 10
    static let titleMax = 60

    // MARK: Words

    /// The row's title: what it is called, "Hi <agent>" for the first chat with no
    /// title, "New chat" for any other with nothing said yet.
    static func title(_ chat: ChatInfo, agent: String) -> String {
        if let t = chat.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        return chat.isFirst ? "Hi \(agent)" : "New chat"
    }

    /// The last line said, "You: how much protein on rest days". Fences of screens
    /// and a tapped answer become plain words. Empty when nothing was said.
    static func lastLine(_ chat: ChatInfo) -> String {
        guard let raw = chat.lastBody, !raw.isEmpty else { return "" }
        var said = words(raw)
        let mine = chat.lastSender == "user"
        if said.isEmpty { return mine ? "" : "Sent a screen" }
        if said.hasPrefix("[yui]") { said = "Tapped an answer" }
        if said.count > 120 { said = String(said.prefix(120)) }
        return mine ? "You: \(said)" : said
    }

    /// A body as one quiet line: no screens, no line breaks.
    static func words(_ body: String) -> String {
        var out: [Substring] = []
        var inFence = false
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") { inFence.toggle(); continue }
            if !inFence, !t.isEmpty { out.append(Substring(t)) }
        }
        return out.joined(separator: " ")
    }

    /// When, in plain words: now, 20m, 2h, 3d, 2w, 4mo.
    static func when(_ date: Date, now: Date = .now) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        if s < 7 * 86_400 { return "\(Int(s / 86_400))d" }
        if s < 60 * 86_400 { return "\(Int(s / (7 * 86_400)))w" }
        return "\(Int(s / (30 * 86_400)))mo"
    }

    /// The time on a row: the last message's, else the chat's last activity.
    static func when(_ chat: ChatInfo, now: Date = .now) -> String {
        guard let d = YuiTime.date(chat.lastMessageAt ?? chat.lastAt) else { return "" }
        return when(d, now: now)
    }

    /// A title someone typed: trimmed, at most 60 characters, nil when empty.
    static func validTitle(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return t.count > titleMax ? String(t.prefix(titleMax)).trimmingCharacters(in: .whitespaces) : t
    }

    // MARK: Order and merge

    /// Newest activity first.
    static func ordered(_ chats: [ChatInfo]) -> [ChatInfo] {
        chats.sorted { a, b in
            let x = YuiTime.date(a.lastAt), y = YuiTime.date(b.lastAt)
            if let x, let y, x != y { return x > y }
            return a.lastAt != b.lastAt ? a.lastAt > b.lastAt : a.id < b.id
        }
    }

    /// The list after a fresh first page (`page`, newest first, `pageSize` asked for).
    /// A short page is the whole list. A full one leaves the older chats already
    /// loaded (scrolled to) where they are; anything newer than its last row that
    /// it does not hold was deleted elsewhere.
    static func merge(_ current: [ChatInfo], page: [ChatInfo], pageSize: Int = Chats.pageSize) -> [ChatInfo] {
        let saved = current.filter(\.saved)
        guard page.count >= pageSize, let oldest = page.last, let cut = YuiTime.date(oldest.lastAt) else {
            return ordered(page)
        }
        let ids = Set(page.map(\.id))
        let older = saved.filter { c in
            guard !ids.contains(c.id), let at = YuiTime.date(c.lastAt) else { return false }
            return at < cut
        }
        return ordered(page + older)
    }

    /// The next page, older chats, added under the list without doubles.
    static func append(_ current: [ChatInfo], older: [ChatInfo]) -> [ChatInfo] {
        let have = Set(current.map(\.id))
        return ordered(current + older.filter { !have.contains($0.id) })
    }

    /// The list narrowed by the search field: title or last line contains the words.
    static func filter(_ chats: [ChatInfo], agent: String, query: String) -> [ChatInfo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return chats }
        return chats.filter { title($0, agent: agent).lowercased().contains(q) || lastLine($0).lowercased().contains(q) }
    }

    // MARK: Delete

    /// A delete of a chat among `saved` chats: the only chat is cleared, not deleted.
    static func deletePlan(saved: Int) -> ChatDelete { saved <= 1 ? .clear : .delete }

    /// The chat to open after `id` goes: the open one stays open, unless it is the
    /// one deleted, then the next newest. Nil when nothing is left (a cleared chat stays).
    static func openAfterDeleting(_ id: String, open: String?, list: [ChatInfo]) -> String? {
        guard open == id else { return open }
        return ordered(list).first { $0.id != id && $0.saved }?.id
    }

    /// What the sheet asks and offers.
    static func sheet(for plan: ChatDelete, title: String, agent: String) -> (question: String, note: String, confirm: String) {
        let note = "Its messages go. \(agent) still remembers what it learned."
        switch plan {
        case .delete: return ("Delete \"\(title)\"?", note, "Delete")
        case .clear: return ("Clear this chat?", note, "Clear")
        }
    }

    // MARK: The empty chat

    /// A chat made on this phone: a new id, nothing on the server until something is said.
    static func draft(now: Date = .now) -> ChatInfo {
        ChatInfo(id: UUID().uuidString.lowercased(), lastAt: ISO8601DateFormatter().string(from: now), saved: false)
    }
}

/// The open agent's chats as the drawer draws them.
@Observable @MainActor
final class ChatList {
    /// Saved chats, newest activity first.
    private(set) var items: [ChatInfo] = []
    /// The open chat, saved or not.
    private(set) var openID: String?
    /// The chat made on this phone with nothing said in it, if one is open.
    private(set) var draft: ChatInfo?
    /// More chats on the server than loaded.
    private(set) var more = false
    private(set) var loaded = false
    /// What went wrong, in plain words, until the person moves on.
    var note: String?

    var open: ChatInfo? { items.first { $0.id == openID } ?? (draft?.id == openID ? draft : nil) }
    /// The open chat has nothing said in it yet, and is not on the server.
    var openIsDraft: Bool { draft != nil && draft?.id == openID }
    var savedCount: Int { items.count }

    func reset() {
        items = []
        openID = nil
        draft = nil
        more = false
        loaded = false
        note = nil
    }

    /// The first page from the server.
    /// `keep`: chats saved from this phone a moment ago, which a list fetched before them lacks.
    func apply(page: [ChatInfo], asked: Int = Chats.pageSize, keep: [ChatInfo] = []) {
        var merged = Chats.merge(items, page: page, pageSize: asked)
        let have = Set(merged.map(\.id))
        merged = Chats.ordered(merged + keep.filter { !have.contains($0.id) })
        items = merged
        more = page.count >= asked
        loaded = true
        if draft != nil, let d = draft, items.contains(where: { $0.id == d.id }) { draft = nil }
    }

    func apply(older: [ChatInfo], asked: Int = Chats.pageSize) {
        items = Chats.append(items, older: older)
        more = older.count >= asked
    }

    func select(_ id: String?) { openID = id }

    /// New chat: the draft that is already open, else a fresh one. Tapping twice gives the same one.
    @discardableResult
    func startNew() -> ChatInfo {
        if let d = draft { openID = d.id; return d }
        let d = Chats.draft()
        draft = d
        openID = d.id
        return d
    }

    /// The draft was said in and now is on the server.
    func saveDraft(lastBody: String? = nil, sender: String? = "user") {
        guard var d = draft else { return }
        d.saved = true
        d.lastBody = lastBody
        d.lastSender = sender
        d.lastMessageAt = d.lastAt
        draft = nil
        items = Chats.ordered(items.filter { $0.id != d.id } + [d])
    }

    /// A rename shown at once.
    func rename(_ id: String, to title: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].title = title
    }

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
        if draft?.id == id { draft = nil }
    }

    /// The person is looking at `id` and has read to the end: the dot goes.
    func markSeen(_ id: String, at: String) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].unread else { return }
        items[i].unread = false
        items[i].seenAt = at
    }

    /// A message sent or read in the open chat moves it to the top with the new line.
    func said(in id: String, sender: String, body: String, at: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].lastSender = sender
        items[i].lastBody = body
        items[i].lastMessageAt = at
        items[i].lastAt = at
        items = Chats.ordered(items)
    }

    /// A chat cleared: nothing said in it.
    func cleared(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].lastBody = nil
        items[i].lastSender = nil
        items[i].lastMessageAt = nil
        items[i].unread = false
    }

    /// The demo account's list, or a fixture.
    func seed(_ chats: [ChatInfo], open id: String?) {
        items = Chats.ordered(chats)
        openID = id ?? items.first?.id
        draft = nil
        more = false
        loaded = true
    }

    #if DEBUG
    /// `-yuiChats <path>`: chats for UI tests and screenshots, the columns of `yui_chat_list`.
    static func debugChats() -> [ChatInfo]? {
        guard let path = UserDefaults.standard.string(forKey: "yuiChats"),
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode([ChatInfo].self, from: data)
    }
    #endif
}

/// PostgREST calls for the chat list, with the session's yui_user token.
@MainActor
struct ChatsClient {
    let account: Account
    let agentID: String

    /// A page of chats, newest activity first.
    func list(limit: Int = Chats.pageSize, offset: Int = 0) async throws -> [ChatInfo] {
        var c = URLComponents(url: YuiBackend.url.appending(path: "rest/v1/yui_chat_list"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "select", value: "*"),
                        URLQueryItem(name: "agent_id", value: "eq.\(agentID)"),
                        URLQueryItem(name: "order", value: "last_at.desc,id.asc"),
                        URLQueryItem(name: "limit", value: String(limit)),
                        URLQueryItem(name: "offset", value: String(offset))]
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return try JSONDecoder().decode([ChatInfo].self, from: try await YuiRelay.data(account, URLRequest(url: c.url!)))
    }

    /// Makes the chat on the server. A chat that is already there counts as made.
    func insert(id: String) async throws {
        guard let user = account.session?.userID else { throw AccountError.signedOut }
        let row: [String: YLValueLite] = ["id": .s(id), "user_id": .s(user), "agent_id": .s(agentID)]
        var req = URLRequest(url: YuiBackend.url.appending(path: "rest/v1/yui_chats"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        req.httpBody = try JSONEncoder().encode(row)
        do {
            _ = try await YuiRelay.data(account, req, chats: true)
        } catch AccountError.server(let code) where code == "http_409" {
            // Already there: an earlier try landed before its answer was lost.
        }
    }

    func rename(_ id: String, to title: String) async throws {
        try await patch(id, ["title": .s(title)])
    }

    /// The person has read to the end of the chat, on this phone or any other.
    func seen(_ id: String, at: String) async throws {
        try await patch(id, ["seen_at": .s(at)])
    }

    func delete(_ id: String) async throws {
        var c = URLComponents(url: YuiBackend.url.appending(path: "rest/v1/yui_chats"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "id", value: "eq.\(id)")]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "DELETE"
        _ = try await YuiRelay.data(account, req, chats: true)
    }

    /// Clear: the chat's messages go, the chat stays.
    func clear(_ id: String) async throws {
        var c = URLComponents(url: YuiBackend.url.appending(path: "rest/v1/yui_messages"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "chat_id", value: "eq.\(id)")]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "DELETE"
        _ = try await YuiRelay.data(account, req, chats: true)
    }

    private func patch(_ id: String, _ fields: [String: YLValueLite]) async throws {
        var c = URLComponents(url: YuiBackend.url.appending(path: "rest/v1/yui_chats"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "id", value: "eq.\(id)")]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        req.httpBody = try JSONEncoder().encode(fields)
        _ = try await YuiRelay.data(account, req, chats: true)
    }
}

/// A JSON string, for the small bodies above.
enum YLValueLite: Encodable {
    case s(String)
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .s(let v): try c.encode(v) }
    }
}
