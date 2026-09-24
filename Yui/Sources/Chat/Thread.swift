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

    enum CodingKeys: String, CodingKey {
        case id, sender, body, kind, meta, reaction
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
    /// anything the person answered, and anything that finished, goes back.
    var relays: Bool { echo != nil || value["done"] == .bool(true) }

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

    /// The newest `limit` rows, oldest first; or everything after `since`.
    /// Pass a `since` a little before the last row seen (`YuiTime.before`):
    /// a row can commit after a later one, and ids dedupe the overlap.
    func fetch(since: String?, limit: Int = 100) async throws -> [ThreadRow] {
        var items = [
            URLQueryItem(name: "select", value: Self.columns),
            URLQueryItem(name: "agent_id", value: "eq.\(agentID)"),
        ]
        if let since {
            items += [URLQueryItem(name: "created_at", value: "gt.\(since)"),
                      URLQueryItem(name: "order", value: "created_at.asc,id.asc")]
        } else {
            items += [URLQueryItem(name: "order", value: "created_at.desc"),
                      URLQueryItem(name: "limit", value: String(limit))]
        }
        var c = URLComponents(url: YuiBackend.url.appending(path: "rest/v1/yui_messages"), resolvingAgainstBaseURL: false)!
        c.queryItems = items
        // Timestamps carry "+00:00"; a bare "+" in a query reads as a space.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        let data = try await request(URLRequest(url: c.url!))
        let rows = try JSONDecoder().decode([ThreadRow].self, from: data)
        return since == nil ? rows.reversed() : rows
    }

    static let columns = "id,sender,body,kind,meta,created_at,delivered_at,handled_at,reaction"

    /// The person's newest row, for how far the agent's turn on it has got.
    func newestFromUser() async throws -> ThreadRow? {
        var c = URLComponents(url: YuiBackend.url.appending(path: "rest/v1/yui_messages"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "select", value: Self.columns),
                        URLQueryItem(name: "agent_id", value: "eq.\(agentID)"),
                        URLQueryItem(name: "sender", value: "eq.user"),
                        URLQueryItem(name: "order", value: "created_at.desc"),
                        URLQueryItem(name: "limit", value: "1")]
        let data = try await request(URLRequest(url: c.url!))
        return try JSONDecoder().decode([ThreadRow].self, from: data).first
    }

    func post(id: String, body: String, kind: String = "text", meta: YLValue? = nil) async throws {
        guard let user = account.session?.userID else { throw AccountError.signedOut }
        var row: [String: YLValue] = ["id": .string(id), "user_id": .string(user), "agent_id": .string(agentID),
                                      "sender": .string("user"), "body": .string(body), "kind": .string(kind)]
        if let meta { row["meta"] = meta }
        var req = URLRequest(url: YuiBackend.url.appending(path: "rest/v1/yui_messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        req.httpBody = try JSONEncoder().encode(YLValue.object(row))
        _ = try await request(req)
    }

    private func request(_ r: URLRequest) async throws -> Data {
        #if DEBUG
        // `-yuiOfflineFlag <path>`: while that file exists the network is "down" (YUI-28 tests).
        if let flag = UserDefaults.standard.string(forKey: "yuiOfflineFlag"), FileManager.default.fileExists(atPath: flag) {
            throw URLError(.notConnectedToInternet)
        }
        #endif
        var req = r
        req.setValue(YuiBackend.publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(try await account.validAccessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AccountError.server("http_\((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
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
