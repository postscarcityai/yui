import Foundation
import YuiLines

/// One row of `yui_messages`. Spec: yuigui/spec/RELAY.md.
struct ThreadRow: Decodable, Sendable {
    let id: String
    let sender: String
    let body: String
    let kind: String
    let meta: YLValue?
    let createdAt: String
    /// The person's rows only: the host picked it up, and the agent's turn on it finished.
    var deliveredAt: String? = nil
    var handledAt: String? = nil
    /// Agent rows only: the person's reaction on it (YUI-49).
    var reaction: String? = nil
    /// The person's rows only: what the agent says it is doing on this turn,
    /// {text?, step?, of?}, written by its host mid-turn (YUI-63).
    var doing: YLValue? = nil
    /// Group rows (YUI-94): the agent the row is to or from. Only a group read asks for it.
    var agentID: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, sender, body, kind, meta, reaction, doing
        case agentID = "agent_id"
        case createdAt = "created_at", deliveredAt = "delivered_at", handledAt = "handled_at"
    }
}

/// An agent message is chat text with Yui Lines inside ```yui fences.
/// Only fenced text is Yui Lines; everything else is a bubble.
enum YuiFence {
    enum Segment: Equatable { case text(String), yl(String) }

    static func split(_ body: String) -> [Segment] {
        var out: [Segment] = []
        var text: [Substring] = []
        var yl: [Substring]? = nil
        func flushText() {
            let t = text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(.text(t)) }
            text = []
        }
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if yl == nil, t == "```yui" {
                flushText()
                yl = []
            } else if yl != nil, t == "```" {
                if let lines = yl, !lines.isEmpty { out.append(.yl(lines.joined(separator: "\n"))) }
                yl = nil
            } else if yl != nil {
                yl!.append(line)
            } else {
                text.append(line)
            }
        }
        // An unclosed fence still renders: the reply may have been cut off.
        if let lines = yl, !lines.isEmpty { out.append(.yl(lines.joined(separator: "\n"))) }
        flushText()
        return out
    }
}

extension YLEvent {
    /// What the agent reads: `[yui] <id> <preset> key=value ...`, keys sorted,
    /// `true` flags bare (`[yui] hiit timer done rounds=8`), lists joined with `|`,
    /// objects flattened with dots (`form.mood=4`).
    var line: String {
        var parts = ["[yui]", id, preset]
        func add(_ key: String, _ v: YLValue) {
            switch v {
            case .bool(true): parts.append(key)
            case .object(let o): for k in o.keys.sorted() { add("\(key).\(k)", o[k]!) }
            default: parts.append("\(key)=\(Self.format(v))")
            }
        }
        for k in value.keys.sorted() { add(k, value[k]!) }
        return parts.joined(separator: " ")
    }

    /// Quiet events (a timer starting, a checklist tick) stay on the phone;
    /// anything the person answered, anything that finished, and every game
    /// event (a tic-tac-toe move needs the agent's answer) goes back.
    var relays: Bool { echo != nil || dismisses || value["done"] == .bool(true) || preset == "game" || (preset == "query" && value["op"] != nil) }

    /// A Dismiss on a Needs you row (YUI-265): goes to the host quietly, which closes the ask on its card.
    /// No chat echo and no agent turn.
    var dismisses: Bool { preset == "menu" && value["dismissed"] == .bool(true) }

    var meta: YLValue {
        var o: [String: YLValue] = ["id": .string(id), "preset": .string(preset), "value": .object(value)]
        if let echo { o["echo"] = .string(echo) }
        return .object(o)
    }

    private static func format(_ v: YLValue) -> String {
        switch v {
        case .string(let s): return quote(s)
        case .number(let n): return YLComponent.format(n)
        case .bool(let b): return b ? "true" : "false"
        case .array(let a): return a.map(format).joined(separator: "|")
        case .null: return "null"
        case .object: return quote(v.jsonString)
        }
    }

    private static func quote(_ s: String) -> String {
        let plain = !s.isEmpty && s.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\"|="))) == nil
        if plain { return s }
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}

extension YLValue {
    var jsonString: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/// PostgREST calls for one agent's thread, with the session's yui_user token.
@MainActor
struct ThreadClient {
    let account: Account
    let agentID: String
    /// The chat this thread is (YUI-169): its rows only. Nil reads and writes the agent's
    /// whole thread, which is what Controls and a server with no chats use.
    var chatID: String? = nil

    /// The newest `limit` rows, oldest first; or everything after `since`.
    /// Pass a `since` a little before the last row seen (`YuiTime.before`):
    /// a row can commit after a later one, and ids dedupe the overlap.
    func fetch(since: String?, limit: Int = 100) async throws -> [ThreadRow] {
        let items = Self.fetchItems(agentID: agentID, chatID: chatID, since: since, limit: limit)
        var c = URLComponents(url: YuiBackend.url.appending(path: "rest/v1/yui_messages"), resolvingAgainstBaseURL: false)!
        c.queryItems = items
        // Timestamps carry "+00:00"; a bare "+" in a query reads as a space.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        let data = try await request(URLRequest(url: c.url!))
        let rows = try JSONDecoder().decode([ThreadRow].self, from: data)
        return since == nil ? rows.reversed() : rows
    }

    /// The `limit` rows said just before `before`, oldest first: the way back through a long chat (YUI-254).
    func fetchOlder(before: String, limit: Int = 100) async throws -> [ThreadRow] {
        var items = Self.fetchItems(agentID: agentID, chatID: chatID, since: nil, limit: limit)
        items.append(URLQueryItem(name: "created_at", value: "lt.\(before)"))
        var c = URLComponents(url: YuiBackend.url.appending(path: "rest/v1/yui_messages"), resolvingAgainstBaseURL: false)!
        c.queryItems = items
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        let data = try await request(URLRequest(url: c.url!))
        return try JSONDecoder().decode([ThreadRow].self, from: data).reversed()
    }

    /// The query of a thread read: the agent's rows, or one chat's when `chatID` is set.
    static func fetchItems(agentID: String, chatID: String?, since: String?, limit: Int = 100) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "select", value: columns),
            URLQueryItem(name: "agent_id", value: "eq.\(agentID)"),
        ]
        if let chatID { items.append(URLQueryItem(name: "chat_id", value: "eq.\(chatID)")) }
        items += [
            // Controls (YUI-70) ride the same table and never show in the thread,
            // except the person's Stop (YUI-190): the record says Stopped where it was.
            URLQueryItem(name: "or", value: "(kind.neq.control,and(sender.eq.user,body.eq.stop))"),
        ]
        if let since {
            items += [URLQueryItem(name: "created_at", value: "gt.\(since)"),
                      URLQueryItem(name: "order", value: "created_at.asc,id.asc")]
        } else {
            items += [URLQueryItem(name: "order", value: "created_at.desc"),
                      URLQueryItem(name: "limit", value: String(limit))]
        }
        return items
    }

    static let columns = "id,sender,body,kind,meta,created_at,delivered_at,handled_at,reaction,doing"

    /// The person's newest row, for how far the agent's turn on it has got.
    func newestFromUser() async throws -> ThreadRow? {
        var c = URLComponents(url: YuiBackend.url.appending(path: "rest/v1/yui_messages"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "select", value: Self.columns),
                        URLQueryItem(name: "agent_id", value: "eq.\(agentID)"),
                        URLQueryItem(name: "sender", value: "eq.user"),
                        URLQueryItem(name: "kind", value: "neq.control"),
                        URLQueryItem(name: "order", value: "created_at.desc"),
                        URLQueryItem(name: "limit", value: "1")]
        if let chatID { c.queryItems?.append(URLQueryItem(name: "chat_id", value: "eq.\(chatID)")) }
        let data = try await request(URLRequest(url: c.url!))
        return try JSONDecoder().decode([ThreadRow].self, from: data).first
    }

    /// The host's answer to a control request (YUI-70), by its `req`. Nil until it lands.
    func controlAnswer(req: String) async throws -> ControlAnswer? {
        var c = URLComponents(url: YuiBackend.url.appending(path: "rest/v1/yui_messages"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "select", value: "meta"),
                        URLQueryItem(name: "agent_id", value: "eq.\(agentID)"),
                        URLQueryItem(name: "kind", value: "eq.control"),
                        URLQueryItem(name: "sender", value: "eq.agent"),
                        URLQueryItem(name: "meta->>req", value: "eq.\(req)"),
                        URLQueryItem(name: "limit", value: "1")]
        struct Row: Decodable { let meta: ControlAnswer }
        let data = try await request(URLRequest(url: c.url!))
        return try JSONDecoder().decode([Row].self, from: data).first?.meta
    }

    /// The host's `key_ask` rows from the last two days (YUI-34). The caller drops the ones already answered.
    func keyAsks() async throws -> [ThreadRow] {
        var c = URLComponents(url: YuiBackend.url.appending(path: "rest/v1/yui_messages"), resolvingAgainstBaseURL: false)!
        let since = ISO8601DateFormatter().string(from: .now.addingTimeInterval(-2 * 86_400))
        c.queryItems = [URLQueryItem(name: "select", value: Self.columns),
                        URLQueryItem(name: "agent_id", value: "eq.\(agentID)"),
                        URLQueryItem(name: "kind", value: "eq.control"),
                        URLQueryItem(name: "sender", value: "eq.agent"),
                        URLQueryItem(name: "meta->>op", value: "eq.key_ask"),
                        URLQueryItem(name: "created_at", value: "gt.\(since)"),
                        URLQueryItem(name: "order", value: "created_at.asc"),
                        URLQueryItem(name: "limit", value: "20")]
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return try JSONDecoder().decode([ThreadRow].self, from: try await request(URLRequest(url: c.url!)))
    }

    func post(id: String, body: String, kind: String = "text", meta: YLValue? = nil) async throws {
        guard let user = account.session?.userID else { throw AccountError.signedOut }
        var row: [String: YLValue] = ["id": .string(id), "user_id": .string(user), "agent_id": .string(agentID),
                                      "sender": .string("user"), "body": .string(body), "kind": .string(kind)]
        if let meta { row["meta"] = meta }
        // The chat it is said in. Settings traffic is the agent's, except the person's Stop, which is the chat's.
        if let chatID, kind != "control" || body == "stop" { row["chat_id"] = .string(chatID) }
        var req = URLRequest(url: YuiBackend.url.appending(path: "rest/v1/yui_messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        req.httpBody = try JSONEncoder().encode(YLValue.object(row))
        _ = try await request(req)
    }

    /// What the agent's other chats hold that belongs to the agent, not to a chat: the
    /// screens (`>2` and up), patches, saves and drawer lines. The open chat reads them
    /// too, so screens stay the agent's whichever chat is open. Newest 100, or after `since`.
    func fetchScoped(since: String?) async throws -> [ThreadRow] {
        guard let chatID else { return [] }
        var items = [
            URLQueryItem(name: "select", value: Self.columns),
            URLQueryItem(name: "agent_id", value: "eq.\(agentID)"),
            URLQueryItem(name: "chat_id", value: "neq.\(chatID)"),
            URLQueryItem(name: "sender", value: "eq.agent"),
            URLQueryItem(name: "kind", value: "eq.text"),
            URLQueryItem(name: "body", value: "match.\(Self.scopedPattern)"),
        ]
        if let since {
            items += [URLQueryItem(name: "created_at", value: "gt.\(since)"),
                      URLQueryItem(name: "order", value: "created_at.asc,id.asc")]
        } else {
            items += [URLQueryItem(name: "order", value: "created_at.desc"), URLQueryItem(name: "limit", value: "100")]
        }
        var c = URLComponents(url: YuiBackend.url.appending(path: "rest/v1/yui_messages"), resolvingAgainstBaseURL: false)!
        c.queryItems = items
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        let rows = try JSONDecoder().decode([ThreadRow].self, from: try await request(URLRequest(url: c.url!)))
        return since == nil ? rows.reversed() : rows
    }

    /// A line that starts with a screen number (`>2`), a patch (`~`), a save or forget, or a drawer `menu`.
    static let scopedPattern = #"(^|\n)[ \t]*(>[0-9]|~|save |forget |menu )"#

    private func request(_ r: URLRequest) async throws -> Data {
        try await YuiRelay.data(account, r)
    }
}

/// One request to Yui's relay with the session's token. `chats`: a refusal that is one of
/// the chat errors (`update_needed`, `limit_reached`, `last_chat`) is thrown as that; `groups`: the same for a
/// group error (`group_archived`, `update_needed`, ...).
@MainActor
enum YuiRelay {
    /// Tests swap in a session with a stand-in relay (a URLProtocol); the app uses the shared one.
    static var session: URLSession = .shared

    static func data(_ account: Account, _ r: URLRequest, chats: Bool = false, groups: Bool = false) async throws -> Data {
        #if DEBUG
        // `-yuiOfflineFlag <path>`: while that file exists the network is "down" (YUI-28 tests).
        if let flag = UserDefaults.standard.string(forKey: "yuiOfflineFlag"), FileManager.default.fileExists(atPath: flag) {
            throw URLError(.notConnectedToInternet)
        }
        #endif
        var req = r
        req.setValue(YuiBackend.publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(try await account.validAccessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            if chats, let e = refusal(data) { throw e }
            if groups, let e = groupRefusal(data) { throw e }
            throw AccountError.server("http_\((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
    }

    /// PostgREST's `{"message": "group_archived"}` as a group error, when it is one we know.
    static func groupRefusal(_ body: Data) -> GroupError? {
        struct Body: Decodable { let message: String? }
        guard let m = (try? JSONDecoder().decode(Body.self, from: body))?.message else { return nil }
        let e = GroupError(message: m)
        if case .other = e { return nil }
        return e
    }

    /// PostgREST's `{"message": "limit_reached"}` as a chat error, when it is one we know.
    static func refusal(_ body: Data) -> ChatError? {
        struct Body: Decodable { let message: String? }
        guard let m = (try? JSONDecoder().decode(Body.self, from: body))?.message else { return nil }
        let e = ChatError(message: m)
        if case .other = e { return nil }
        return e
    }
}

/// Server timestamps (`2026-09-24T10:47:09.714466+00:00`).
enum YuiTime {
    /// `ts` moved `seconds` earlier, for an overlapping poll. Unparseable: `ts` as is.
    static func before(_ ts: String, seconds: TimeInterval) -> String {
        var base = ts
        var zone = ""
        if let z = base.range(of: #"(Z|[+-]\d\d:\d\d)$"#, options: .regularExpression) {
            zone = String(base[z]); base.removeSubrange(z)
        }
        if let dot = base.firstIndex(of: ".") { base = String(base[..<dot]) }
        guard let date = try? Date(base + (zone.isEmpty ? "Z" : zone), strategy: .iso8601) else { return ts }
        return date.addingTimeInterval(-seconds).formatted(.iso8601)
    }

    /// A Postgres timestamp ("2026-09-24T12:15:45.187+00:00") as a date, to the second.
    static func date(_ ts: String) -> Date? {
        var base = ts
        var zone = "Z"
        if let z = base.range(of: #"(Z|[+-]\d\d:\d\d)$"#, options: .regularExpression) {
            zone = String(base[z]); base.removeSubrange(z)
        }
        if let dot = base.firstIndex(of: ".") { base = String(base[..<dot]) }
        return try? Date(base + zone, strategy: .iso8601)
    }
}
