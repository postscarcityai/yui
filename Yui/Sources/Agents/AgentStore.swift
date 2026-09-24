import Foundation
import Observation

/// One of the user's agents, as the `yui-agents` registry API returns it.
/// Spec: yuigui/spec/AGENTS.md.
struct YuiAgent: Codable, Identifiable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case pending, connected, offline }

    let id: String
    var name: String
    var handle: String
    var color: String
    var avatar: String?
    var kind: String
    var connectorID: String?
    var connectorName: String?
    var remoteRef: String?
    var status: Status
    var lastSeenAt: Date?
    var isDefault: Bool
    var sort: Int

    enum CodingKeys: String, CodingKey {
        case id, name, handle, color, avatar, kind, status, sort
        case connectorID = "connector_id", connectorName = "connector_name", remoteRef = "remote_ref"
        case lastSeenAt = "last_seen_at", isDefault = "is_default"
    }
}

/// A 6-digit code the host types into `hermes -p <profile> yui pair`.
struct PairingCode: Codable, Equatable, Sendable {
    let code: String
    let expiresAt: Date
    enum CodingKeys: String, CodingKey { case code, expiresAt = "expires_at" }
}

/// A management token for Settings > Agent access. The secret is only ever
/// in the create reply.
struct AgentAccessToken: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var createdAt: Date
    var lastUsedAt: Date?
    enum CodingKeys: String, CodingKey { case id, name, createdAt = "created_at", lastUsedAt = "last_used_at" }
}

/// The user's agents: list, add, rename, recolor, reorder, default, remove.
/// Everything goes through the `yui-agents` edge function with the session's
/// access token. The demo account keeps it all in memory for screenshots.
@MainActor @Observable
final class AgentStore {
    private(set) var agents: [YuiAgent] = []
    private(set) var tokens: [AgentAccessToken] = []
    private(set) var loaded = false
    var error: String?

    /// The agent the chat talks to. Falls back to the default agent.
    var selectedID: String? {
        didSet { UserDefaults.standard.set(selectedID, forKey: "selectedAgent") }
    }
    var selected: YuiAgent? {
        agents.first { $0.id == selectedID } ?? agents.first { $0.isDefault } ?? agents.first
    }

    private let account: Account
    private var isDemo: Bool { account.session?.userID == "demo" }

    init(account: Account) {
        self.account = account
        selectedID = UserDefaults.standard.string(forKey: "selectedAgent")
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-yuiDemoAccount") {
            agents = ProcessInfo.processInfo.arguments.contains("-yuiNoAgents") ? [] : Self.demo
            loaded = true
        }
        #endif
    }

    // MARK: Agents

    /// Sign out or account switch: forget the last account's agents.
    func reset() {
        agents = []
        tokens = []
        loaded = false
        error = nil
    }

    func refresh() async {
        if isDemo { return }
        do {
            let r: ListReply = try await call(["action": "list"])
            agents = r.agents
            loaded = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Makes a pending agent and a pairing code for it.
    func add(name: String, color: String) async throws -> (YuiAgent, PairingCode) {
        if isDemo {
            let a = YuiAgent(id: UUID().uuidString, name: name, handle: name.lowercased(), color: color,
                             kind: "hermes", status: .pending, isDefault: agents.isEmpty, sort: agents.count)
            agents.append(a)
            return (a, Self.demoCode)
        }
        let r: CreateReply = try await call(["action": "create", "name": name, "color": color, "pair": true])
        agents.append(r.agent)
        guard let pairing = r.pairing else { throw AccountError.server("no_code") }
        return (r.agent, pairing)
    }

    func newCode(for agent: YuiAgent) async throws -> PairingCode {
        if isDemo { return Self.demoCode }
        return try await call(["action": "pair_code", "agent_id": agent.id])
    }

    func update(_ agent: YuiAgent, name: String? = nil, color: String? = nil, makeDefault: Bool = false) async {
        if isDemo {
            guard let i = agents.firstIndex(of: agent) else { return }
            if let name { agents[i].name = name }
            if let color { agents[i].color = color }
            if makeDefault { for j in agents.indices { agents[j].isDefault = j == i } }
            return
        }
        var body: [String: Any] = ["action": "update", "id": agent.id]
        if let name { body["name"] = name }
        if let color { body["color"] = color }
        if makeDefault { body["is_default"] = true }
        do {
            let _: AgentReply = try await call(body)
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Removes the agent and, on the server, its whole conversation.
    func remove(_ agent: YuiAgent) async {
        agents.removeAll { $0.id == agent.id }
        if isDemo {
            if agent.isDefault, !agents.isEmpty { agents[0].isDefault = true }
            return
        }
        do {
            let _: DeleteReply = try await call(["action": "delete", "id": agent.id])
        } catch {
            self.error = error.localizedDescription
        }
        await refresh()
    }

    func move(from source: IndexSet, to destination: Int) {
        agents.move(fromOffsets: source, toOffset: destination)
        for i in agents.indices { agents[i].sort = i }
        guard !isDemo else { return }
        let ids = agents.map(\.id)
        Task {
            do { let _: OKReply = try await call(["action": "reorder", "ids": ids]) } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: Agent access tokens

    func refreshTokens() async {
        if isDemo { return }
        do {
            let r: TokenListReply = try await call(["action": "token_list"])
            tokens = r.tokens
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Returns the secret. It is shown once and never stored in the app.
    func createToken(name: String) async throws -> String {
        if isDemo {
            tokens.append(AgentAccessToken(id: UUID().uuidString, name: name, createdAt: .now))
            return "yui_mt_demo0000000000000000000000000000000000"
        }
        let r: TokenCreateReply = try await call(["action": "token_create", "name": name])
        await refreshTokens()
        return r.token
    }

    func revokeToken(_ token: AgentAccessToken) async {
        tokens.removeAll { $0.id == token.id }
        if isDemo { return }
        do { let _: OKRevoked = try await call(["action": "token_revoke", "id": token.id]) } catch {
            self.error = error.localizedDescription
        }
        await refreshTokens()
    }

    // MARK: Network

    private struct ListReply: Decodable { let agents: [YuiAgent] }
    private struct CreateReply: Decodable { let agent: YuiAgent; let pairing: PairingCode? }
    private struct AgentReply: Decodable { let agent: YuiAgent }
    private struct DeleteReply: Decodable { let deleted: Bool }
    private struct OKReply: Decodable { let ok: Bool }
    private struct OKRevoked: Decodable { let revoked: Bool }
    private struct TokenListReply: Decodable { let tokens: [AgentAccessToken] }
    private struct TokenCreateReply: Decodable { let token: String }
    private struct ErrorReply: Decodable { let error: String }

    private func call<T: Decodable>(_ body: [String: Any]) async throws -> T {
        let payload = try JSONSerialization.data(withJSONObject: body)
        let token = try await account.validAccessToken()
        var req = URLRequest(url: YuiBackend.function("yui-agents"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(YuiBackend.publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = payload
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode(ErrorReply.self, from: data))?.error ?? "error"
            throw AccountError.server(code)
        }
        return try Self.decoder.decode(T.self, from: data)
    }

    /// Postgres timestamps: "2026-09-24T03:52:13.95604+00:00", any number of fraction digits.
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let raw = try dec.singleValueContainer().decode(String.self)
            let s = raw.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
            guard let date = try? Date(s, strategy: .iso8601) else {
                throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: raw))
            }
            return date
        }
        return d
    }()

    // MARK: Demo (DEBUG screenshots)

    static let demo = [
        YuiAgent(id: "demo-yui", name: "Yui", handle: "yui", color: "brand", avatar: "yui", kind: "hermes",
                 connectorName: "Mac mini", remoteRef: "yui", status: .connected, lastSeenAt: .now,
                 isDefault: true, sort: 0),
    ]
    static let demoCode = PairingCode(code: "482913", expiresAt: .now.addingTimeInterval(600))
}
