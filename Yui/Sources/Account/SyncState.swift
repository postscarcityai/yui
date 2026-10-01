import Foundation
import UIKit

// One Yui across phone and web (YUI-249). The words half typed in a thread follow the person to their other
// devices through `yui_sync_state` (migration 20261001200000): one row per person, agent and key, the server
// stamps `updated_at`, an empty value is a cleared draft. Thread, chats, screens, the shelf's saves and read
// state already share through yui_messages and yui_chats. The web twin is site/lib/web/state.mjs
// (createKeySync); the rule is the same: a newer remote value wins when nothing local is waiting to go up,
// a local change that is waiting wins and goes up. A pasted key is never sent (YUI-34).

/// Keeps one agent's draft in step with the server.
@MainActor
final class DraftSync {
    private let account: Account
    private let agentID: String
    private let read: () -> String
    private let write: (String) -> Void
    private let changedAt: () -> Date

    /// The value last known to be on the server, and that row's time.
    private var pushed: String?
    private var seen = Date.distantPast
    private var pending: Task<Void, Never>?
    private var beat: Task<Void, Never>?
    private var pulling = false

    init(account: Account, agentID: String, read: @escaping () -> String, write: @escaping (String) -> Void,
         changedAt: @escaping () -> Date) {
        self.account = account
        self.agentID = agentID
        self.read = read
        self.write = write
        self.changedAt = changedAt
    }

    func start() {
        beat?.cancel()
        beat = Task { [weak self] in
            while !Task.isCancelled {
                if UIApplication.shared.applicationState == .active { await self?.pull() }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        beat?.cancel(); beat = nil
        pending?.cancel(); pending = nil
    }

    /// The words changed here. Empty (sent or deleted) goes up at once; typing waits for a pause.
    func changed(now: Bool = false) {
        pending?.cancel()
        pending = Task { [weak self] in
            if !now { try? await Task.sleep(for: .milliseconds(700)) }
            guard !Task.isCancelled else { return }
            await self?.push()
        }
    }

    private func safe(_ words: String) -> String { KeyShape.find(in: words) != nil ? "" : words }

    private func push() async {
        let value = safe(read())
        if value == pushed { return }
        do {
            _ = try await SyncStateClient(account: account).put(agentID: agentID, key: "draft", value: value)
            pushed = value
            seen = Date()
        } catch { /* offline: the next change or poll tries again */ }
    }

    func pull() async {
        guard !pulling else { return }
        pulling = true
        defer { pulling = false }
        guard let rows = try? await SyncStateClient(account: account).list(agentID: agentID) else { return }
        let local = read()
        guard let row = rows.first(where: { $0.key == "draft" }) else {
            if pushed == nil { pushed = "" }
            if local != pushed { changed() }
            return
        }
        let when = row.updatedAt
        if pushed == nil {
            // First look. Remote wins when it was written after this phone last changed the words.
            pushed = row.value; seen = when
            if row.value != local {
                if when >= changedAt() || local.isEmpty { write(row.value) } else { changed() }
            }
            return
        }
        if when <= seen && row.value == pushed { return }
        if row.value == pushed { seen = when; return }
        if local == pushed {
            pushed = row.value; seen = when
            if row.value != local { write(row.value) }
        } else {
            // The words here are newer and waiting: they go up.
            seen = when; pushed = row.value
            changed()
        }
    }
}

/// PostgREST calls for `yui_sync_state`, with the session's yui_user token.
@MainActor
struct SyncStateClient {
    let account: Account

    struct Row: Decodable {
        let key: String
        let value: String
        let device: String?
        let updatedAt: Date
        enum CodingKeys: String, CodingKey { case key, value, device, updatedAt = "updated_at" }
    }

    func list(agentID: String) async throws -> [Row] {
        var c = URLComponents(url: YuiBackend.url.appending(path: "rest/v1/yui_sync_state"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "select", value: "key,value,device,updated_at"),
                        URLQueryItem(name: "agent_id", value: "eq.\(agentID)")]
        let data = try await YuiRelay.data(account, URLRequest(url: c.url!))
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let t = f.date(from: s) { return t }
            f.formatOptions = [.withInternetDateTime]
            if let t = f.date(from: s) { return t }
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "date \(s)"))
        }
        return try d.decode([Row].self, from: data)
    }

    @discardableResult
    func put(agentID: String, key: String, value: String) async throws -> Data {
        guard let user = account.session?.userID else { throw AccountError.signedOut }
        var c = URLComponents(url: YuiBackend.url.appending(path: "rest/v1/yui_sync_state"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "on_conflict", value: "user_id,agent_id,key")]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        let row: [String: String] = ["user_id": user, "agent_id": agentID, "key": key, "value": value, "device": "iphone"]
        req.httpBody = try JSONEncoder().encode(row)
        return try await YuiRelay.data(account, req)
    }
}
