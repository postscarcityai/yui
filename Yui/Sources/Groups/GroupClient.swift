import Foundation
import YuiLines

/// PostgREST calls for group threads (YUI-94), with the session's yui_user token.
/// Spec: yuigui/spec/GROUPS.md, section 7.
@MainActor
struct GroupClient {
    let account: Account

    private func url(_ table: String, _ items: [URLQueryItem] = []) -> URL {
        var c = URLComponents(url: YuiBackend.url.appending(path: "rest/v1/\(table)"), resolvingAgainstBaseURL: false)!
        if !items.isEmpty { c.queryItems = items }
        // Timestamps carry "+00:00"; a bare "+" in a query reads as a space.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }

    private func call(_ method: String, _ url: URL, body: Encodable? = nil) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
            req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        return try await YuiRelay.data(account, req, groups: true)
    }

    static let threadColumns = "id,title,lead,max_hops,max_turns,archived_at,created_at,yui_thread_members(agent_id,left_at)"

    /// The person's groups, archived ones left out.
    func list() async throws -> [GroupInfo] {
        let data = try await call("GET", url("yui_threads", [
            URLQueryItem(name: "select", value: Self.threadColumns),
            URLQueryItem(name: "archived_at", value: "is.null"),
            URLQueryItem(name: "order", value: "created_at.desc")]))
        return GroupRows.ordered(try JSONDecoder().decode([GroupInfo].self, from: data))
    }

    /// Makes the group: the thread (the lead is seated by trigger), then the other members.
    /// Refused with `update_needed` while this build is below `group_min_build`.
    func create(id: String, title: String, lead: String, members: [String]) async throws {
        guard let user = account.session?.userID else { throw AccountError.signedOut }
        _ = try await call("POST", url("yui_threads"),
                           body: ["id": id, "user_id": user, "title": title, "lead": lead])
        let others = members.filter { $0 != lead }
        if !others.isEmpty { try await add(others, to: id) }
    }

    func add(_ agents: [String], to thread: String) async throws {
        guard let user = account.session?.userID else { throw AccountError.signedOut }
        let rows = agents.map { ["thread_id": thread, "agent_id": $0, "user_id": user] }
        do {
            _ = try await call("POST", url("yui_thread_members"), body: rows)
        } catch AccountError.server(let code) where code == "http_409" {
            // One of them left earlier: seat it again.
            for a in agents { try await rejoin(a, in: thread) }
        }
    }

    private func rejoin(_ agent: String, in thread: String) async throws {
        _ = try await call("PATCH", url("yui_thread_members", [
            URLQueryItem(name: "thread_id", value: "eq.\(thread)"), URLQueryItem(name: "agent_id", value: "eq.\(agent)")]),
            body: ["left_at": JSONNull()])
    }

    func leave(_ agent: String, thread: String) async throws {
        _ = try await call("PATCH", url("yui_thread_members", [
            URLQueryItem(name: "thread_id", value: "eq.\(thread)"), URLQueryItem(name: "agent_id", value: "eq.\(agent)")]),
            body: ["left_at": ISO8601DateFormatter().string(from: .now)])
    }

    func rename(_ thread: String, to title: String) async throws { try await patch(thread, ["title": title]) }
    func makeLead(_ agent: String, thread: String) async throws { try await patch(thread, ["lead": agent]) }
    func setMaxHops(_ n: Int, thread: String) async throws { try await patch(thread, ["max_hops": n]) }
    func archive(_ thread: String) async throws {
        try await patch(thread, ["archived_at": ISO8601DateFormatter().string(from: .now)])
    }

    private func patch(_ thread: String, _ fields: [String: Encodable]) async throws {
        _ = try await call("PATCH", url("yui_threads", [URLQueryItem(name: "id", value: "eq.\(thread)")]),
                           body: fields.mapValues(AnyEncodable.init))
    }

    static let messageColumns = ThreadClient.columns + ",agent_id"

    /// The group's newest rows, oldest first; or everything after `since`.
    func rows(thread: String, since: String?, limit: Int = 100) async throws -> [ThreadRow] {
        var items = [URLQueryItem(name: "select", value: Self.messageColumns),
                     URLQueryItem(name: "thread_id", value: "eq.\(thread)")]
        if let since {
            items += [URLQueryItem(name: "created_at", value: "gt.\(since)"),
                      URLQueryItem(name: "order", value: "created_at.asc,id.asc")]
        } else {
            items += [URLQueryItem(name: "order", value: "created_at.desc"), URLQueryItem(name: "limit", value: String(limit))]
        }
        let rows = try JSONDecoder().decode([ThreadRow].self, from: try await call("GET", url("yui_messages", items)))
        return since == nil ? rows.reversed() : rows
    }

    /// The person's words. `agent` is any member (the trigger picks the real one); `to` the addressed ids.
    func say(id: String, thread: String, agent: String, words: String, to: [String], echo: String? = nil, photos: [String] = []) async throws {
        guard let user = account.session?.userID else { throw AccountError.signedOut }
        var meta: [String: YLValue] = ["group": .object(["to": .array(to.map { .string($0) })])]
        if let kept = Attachments.meta(paths: photos)?.object?["photos"] { meta["photos"] = kept }
        if let echo { meta["echo"] = .string(echo) }
        try await insert(["id": .string(id), "user_id": .string(user), "agent_id": .string(agent),
                          "thread_id": .string(thread), "sender": .string("user"), "kind": .string("text"),
                          "body": .string(words), "meta": .object(meta)])
    }

    /// Let it: the held ask goes out on a fresh budget.
    func letIt(guard guardID: String, thread: String, lead: String) async throws {
        try await control(thread: thread, lead: lead, body: "[yui] group continue guard=\(guardID)",
                          meta: ["control": .string("continue"), "guard": .string(guardID)])
    }

    /// Stop: every handoff not picked up yet is cancelled.
    func stop(thread: String, lead: String) async throws {
        try await control(thread: thread, lead: lead, body: "[yui] group stop", meta: ["control": .string("stop")])
    }

    private func control(thread: String, lead: String, body: String, meta: [String: YLValue]) async throws {
        guard let user = account.session?.userID else { throw AccountError.signedOut }
        try await insert(["id": .string(UUID().uuidString.lowercased()), "user_id": .string(user), "agent_id": .string(lead),
                          "thread_id": .string(thread), "sender": .string("user"), "kind": .string("text"),
                          "body": .string(body), "meta": .object(["group": .object(meta)])])
    }

    private func insert(_ row: [String: YLValue]) async throws {
        _ = try await call("POST", url("yui_messages"), body: YLValue.object(row))
    }
}

private struct JSONNull: Encodable {
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encodeNil() }
}

private struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
