import Foundation
import Observation

/// One of the user's agents, as the `yui-agents` registry API returns it.
/// Spec: yuigui/spec/AGENTS.md.
struct YuiAgent: Codable, Identifiable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case pending, connected, offline
        /// A value this build doesn't know reads offline instead of failing the whole list.
        init(from decoder: Decoder) throws {
            self = Status(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .offline
        }
    }

    /// What the host's heartbeat says (YUI-28). `asleep`: it went quiet without
    /// saying goodbye (the computer slept or lost its network); `offline`: its
    /// gateway stopped, or it was removed. `notListening` (YUI-64): paired,
    /// but no gateway on its computer has started reading its thread yet.
    enum Liveness: String, Sendable {
        case online, asleep, offline, pending
        case notListening = "not_listening"
        /// A shared agent whose owner's sandbox stopped passing (YUI-95): no turns run.
        case paused
        /// What VoiceOver says: "Talking to Bravo, not listening yet".
        var spoken: String {
            switch self {
            case .pending: "offline"
            case .notListening: "not listening yet"
            case .paused: "paused by its owner"
            default: rawValue
            }
        }
    }

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
    /// Its look (`yui_agents.theme`): colors, shape, type, motion, preferred screens.
    var theme: AgentLook? = nil
    /// Its answers don't push to this person's phones (YUI-24). Nil from older servers.
    var pushMuted: Bool? = nil
    /// online / asleep / offline / pending (YUI-28), not_listening (YUI-64). Nil from older servers.
    var presence: String? = nil
    /// The /commands its host accepts, as its plugin reports them (YUI-61).
    /// Nil: the host has no registry (MCP, OpenClaw, webhook), so no suggestions.
    var commands: [AgentCommand]? = nil
    /// Someone else's agent, shared with this person (YUI-57). Nil from older servers.
    var shared: Bool? = nil
    /// Who shared it, as the person sees it: "Sam".
    var sharedBy: String? = nil
    /// Its first message, from the invite (YUI-95).
    var firstMessage: String? = nil
    /// Its host reports a sandbox that passes all five rules: it can be shared.
    var clientSafe: Bool? = nil
    /// An owned agent's broken rules ("terminal: local shell"); [] when it is safe (YUI-97).
    var shareWhy: [String]? = nil
    /// What its host lets the drawer's Controls tab do (YUI-70). Nil: the host shares no settings.
    var controls: AgentControls? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, handle, color, avatar, kind, status, sort, theme
        case connectorID = "connector_id", connectorName = "connector_name", remoteRef = "remote_ref"
        case lastSeenAt = "last_seen_at", isDefault = "is_default", pushMuted = "push_muted", presence, commands, shared
        case sharedBy = "shared_by", firstMessage = "first_message", clientSafe = "client_safe", shareWhy = "share_why"
        case controls
    }
}

/// One slash command an agent's host accepts: `/new [name]`, "Start a new session".
/// Spec: yuigui/spec/AGENTS.md "Commands".
struct AgentCommand: Codable, Equatable, Hashable, Sendable, Identifiable {
    let name: String
    var description: String
    /// What goes after it, e.g. `[name]` or `<prompt>`. Nil when it takes nothing.
    var args: String? = nil
    var id: String { name }
}

extension YuiAgent {
    var isYui: Bool { avatar == "yui" }
    var muted: Bool { pushMuted ?? false }
    var isShared: Bool { shared ?? false }
    /// "Not safe to share: it has a shell on your computer", in the owner's words.
    /// Nil for a shared agent and on servers that don't say.
    var shareRule: String? {
        guard !isShared, let why = shareWhy else { return nil }
        return why.first.map(Self.plain)
    }
    var safeToShare: Bool { !isShared && (clientSafe ?? false) }

    /// One broken rule in plain words (grant.py PLAIN says the same).
    static func plain(_ rule: String) -> String {
        let words: [(String, String)] = [
            ("no sandbox report", "its computer hasn't reported a sandbox yet"),
            ("its host has not", "its computer hasn't reported a sandbox yet"),
            ("profile:", "it shares a Hermes profile with your other agents"),
            ("keys:", "its profile holds keys beyond its model key"),
            ("terminal:", "it has a shell on your computer"),
            ("files:", "it can read your files"),
            ("reach:", "it can reach your other tools"),
            ("memory:", "its memory is shared between people"),
            ("runner:", "its model runs as an agent with a shell"),
        ]
        return words.first { rule.hasPrefix($0.0) }?.1 ?? rule
    }
    var liveness: Liveness {
        if let p = presence.flatMap(Liveness.init(rawValue:)) { return p }
        switch status {
        case .connected: return .online
        case .pending: return .pending
        case .offline: return .offline
        }
    }
    /// The one step left for an agent that isn't listening: start its profile's gateway.
    var restartCommand: String {
        guard let ref = remoteRef, ref != "default" else { return "hermes gateway restart" }
        return "hermes -p \(ref) gateway restart"
    }
    /// The whole app wears this while its thread is open.
    var yuiTheme: YuiTheme { AgentLook.theme(theme, name: handle.isEmpty ? name : handle, isYui: isYui) }
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
    /// An invited person's first name, for "Hi Maya. Sam set these up for you." (YUI-97).
    private(set) var firstName: String?
    /// "Basil is no longer shared with you.": shared agents gone since the app opened.
    /// Kept until the app is next launched, never stored.
    private(set) var unshared: [String] = []
    /// One quiet line over everything, when the thread on screen was taken away.
    var notice: String?

    /// Shared agents, who set them up: "Sam", or "Sam and Alex".
    var sharers: String? {
        var seen: [String] = []
        for a in agents where a.isShared { if let by = a.sharedBy, !seen.contains(by) { seen.append(by) } }
        return seen.isEmpty ? nil : ListFormatter.localizedString(byJoining: seen)
    }
    /// Every agent here was given to this person: an invited client's account.
    var onlyShared: Bool { !agents.isEmpty && agents.allSatisfy(\.isShared) }

    /// The agent the chat talks to. Falls back to the default agent.
    var selectedID: String? {
        didSet {
            UserDefaults.standard.set(selectedID, forKey: "selectedAgent")
            // A tap on an agent (YUI-102): thread_open runs until its newest messages show.
            if selectedID != oldValue, selectedID != nil { Perf.shared.threadTapped() }
        }
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
            let args = ProcessInfo.processInfo.arguments
            agents = args.contains("-yuiNoAgents") ? [] : args.contains("-yuiDemoAgents") ? Self.demoCrew
                : args.contains("-yuiDemoShared") ? Self.demoShared : Self.demo
            // -yuiDemoControls: the demo's own Hermes agents report every section (YUI-70);
            // Counsel stays offline, Nova's host shares nothing.
            if args.contains("-yuiDemoControls") {
                agents = agents.map { a in
                    var a = a
                    if !a.isShared, a.id != "demo-nova" { a.controls = Self.demoReport }
                    if a.id != "demo-counsel", a.presence == nil { a.presence = "online" }
                    return a
                }
            }
            if args.contains("-yuiDemoShared") {
                firstName = "Maya"
                // -yuiDemoRevoke <s>: Basil is revoked after s seconds, as a push would tell it (YUI-97).
                let after = UserDefaults.standard.double(forKey: "yuiDemoRevoke")
                if after > 0 {
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(after))
                        guard let self else { return }
                        self.apply(self.agents.filter { $0.handle != "basil" })
                    }
                }
            }
            // -yuiAgent <handle> opens that agent's thread.
            if let h = UserDefaults.standard.string(forKey: "yuiAgent") { selectedID = agents.first { $0.handle == h }?.id }
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
        firstName = nil
        unshared = []
        notice = nil
    }

    func refresh() async {
        if isDemo { return }
        do {
            let r: ListReply = try await call(["action": "list"])
            apply(r.agents)
            firstName = r.firstName
            loaded = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// A new list. A shared agent that is gone was revoked (YUI-97): the list says
    /// so in one quiet line, and if its thread was open it closes with the same line.
    func apply(_ new: [YuiAgent]) {
        let gone = agents.filter { old in old.isShared && !new.contains { $0.id == old.id } }
        let wasOpen = gone.contains { $0.id == selected?.id }
        agents = new
        guard !gone.isEmpty else { return }
        for a in gone where !unshared.contains(a.name) { unshared.append(a.name) }
        if wasOpen, let a = gone.first(where: { $0.id == selectedID }) ?? gone.first {
            selectedID = nil
            notice = Self.unsharedLine(a.name)
        }
    }

    static func unsharedLine(_ name: String) -> String { "\(name) is no longer shared with you." }

    /// Makes a pending agent and a pairing code for it.
    func add(name: String, color: String) async throws -> (YuiAgent, PairingCode) {
        if isDemo {
            let a = YuiAgent(id: UUID().uuidString, name: name, handle: name.lowercased(), color: color,
                             kind: "hermes", status: .pending, isDefault: agents.isEmpty, sort: agents.count)
            agents.append(a)
            #if DEBUG
            // -yuiDemoPairAfter <s>: the new agent comes online after s seconds, as if its host just paired (SOC-3 videos).
            let after = UserDefaults.standard.double(forKey: "yuiDemoPairAfter")
            if after > 0 {
                Task {
                    try? await Task.sleep(for: .seconds(after))
                    guard let i = agents.firstIndex(where: { $0.id == a.id }) else { return }
                    agents[i].status = .connected
                    agents[i].connectorName = "your Mac"
                    agents[i].lastSeenAt = .now
                }
            }
            #endif
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

    func update(_ agent: YuiAgent, name: String? = nil, color: String? = nil, theme: AgentLook? = nil,
                makeDefault: Bool = false, pushMuted: Bool? = nil) async {
        guard let i = agents.firstIndex(where: { $0.id == agent.id }) else { return }
        // The look shows at once; the server write follows.
        if let theme { agents[i].theme = theme }
        if let pushMuted { agents[i].pushMuted = pushMuted }
        if isDemo {
            if let name { agents[i].name = name }
            if let color { agents[i].color = color }
            if makeDefault { for j in agents.indices { agents[j].isDefault = j == i } }
            return
        }
        var body: [String: Any] = ["action": "update", "id": agent.id]
        if let name { body["name"] = name }
        if let color { body["color"] = color }
        if let theme, let data = try? JSONEncoder().encode(theme),
           let json = try? JSONSerialization.jsonObject(with: data) { body["theme"] = json }
        if makeDefault { body["is_default"] = true }
        if let pushMuted { body["push_muted"] = pushMuted }
        do {
            let _: AgentReply = try await call(body)
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// An agent restyled itself with a YL `theme` line (spec YL.md, "theme").
    /// `at` is the message's time: a line older than the current look (say, a
    /// pick the person made since) never wins, so replaying history is safe.
    func applyThemeLine(agentID: String, props: [String: String], at: String) async {
        guard let agent = agents.first(where: { $0.id == agentID }) else { return }
        if let current = agent.theme?.at, let old = Self.instant(current), let new = Self.instant(at), new <= old { return }
        let look = (agent.theme ?? AgentLook()).applying(props, at: at, by: "agent")
        await update(agent, theme: look)
    }

    /// The person picked a look in the agent's settings.
    func setLook(_ agent: YuiAgent, preset: String?) async {
        var look = AgentLook(preset: preset, style: agent.theme?.style)
        look.at = Date.now.formatted(.iso8601)
        look.by = "user"
        await update(agent, theme: look)
    }

    /// Postgres or ISO-8601 time, any number of fraction digits.
    static func instant(_ s: String) -> Date? {
        var frac = 0.0
        var base = s
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
            frac = Double("0" + s[r]) ?? 0
            base.removeSubrange(r)
        }
        return (try? Date(base, strategy: .iso8601))?.addingTimeInterval(frac)
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

    // MARK: Connect an MCP client (INT-19)

    /// A connect request opened from `yui://connect/<id>` or yuigui.com/a/<id>,
    /// waiting for its sheet (and for sign-in, when signed out).
    var pendingConnect: ConnectRequestID?

    func connectRequest(_ id: String) async throws -> ConnectRequest {
        try await call(["action": "app_request", "id": id], function: "yui-oauth")
    }

    /// Allow: for an existing agent, or a new one named `name`. Returns the agent's id.
    func approveConnect(_ id: String, agentID: String?, name: String?) async throws -> String {
        var body: [String: Any] = ["action": "app_approve", "id": id]
        if let agentID { body["agent_id"] = agentID } else if let name { body["name"] = name }
        let r: ConnectApproved = try await call(body, function: "yui-oauth")
        await refresh()
        return r.agent.id
    }

    func denyConnect(_ id: String) async throws {
        let _: ConnectRequest.Brief = try await call(["action": "app_deny", "id": id], function: "yui-oauth")
    }

    private struct ConnectApproved: Decodable {
        struct Agent: Decodable { let id: String }
        let agent: Agent
    }

    private struct ListReply: Decodable {
        let agents: [YuiAgent]
        var firstName: String? = nil
        enum CodingKeys: String, CodingKey { case agents, firstName = "first_name" }
    }
    private struct CreateReply: Decodable { let agent: YuiAgent; let pairing: PairingCode? }
    private struct AgentReply: Decodable { let agent: YuiAgent }
    private struct DeleteReply: Decodable { let deleted: Bool }
    private struct OKReply: Decodable { let ok: Bool }
    private struct OKRevoked: Decodable { let revoked: Bool }
    private struct TokenListReply: Decodable { let tokens: [AgentAccessToken] }
    private struct TokenCreateReply: Decodable { let token: String }
    private struct ErrorReply: Decodable { let error: String }

    private func call<T: Decodable>(_ body: [String: Any], function: String = "yui-agents") async throws -> T {
        let payload = try JSONSerialization.data(withJSONObject: body)
        let token = try await account.validAccessToken()
        var req = URLRequest(url: YuiBackend.function(function))
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
    /// `-yuiDemoAgents`: a few agents, each in its own look, for screenshots.
    static let demoCrew = demo + [
        YuiAgent(id: "demo-coach", name: "Coach", handle: "coach", color: "butter", kind: "hermes",
                 connectorName: "Mac mini", remoteRef: "coach", status: .connected, lastSeenAt: .now,
                 isDefault: false, sort: 1, theme: AgentLook(style: ["screen": "full", "buttons": "stack"]),
                 clientSafe: true, shareWhy: []),
        YuiAgent(id: "demo-wizard", name: "Wizard", handle: "wizard", color: "lavender", kind: "hermes",
                 connectorName: "Mac mini", remoteRef: "wizard", status: .connected, lastSeenAt: .now,
                 isDefault: false, sort: 2, clientSafe: false, shareWhy: ["terminal: local shell", "files: the host's files"]),
        YuiAgent(id: "demo-counsel", name: "Counsel", handle: "counsel", color: "mint", kind: "hermes",
                 connectorName: "Mac mini", remoteRef: "counsel", status: .offline, lastSeenAt: .now,
                 isDefault: false, sort: 3),
        YuiAgent(id: "demo-nova", name: "Nova", handle: "nova", color: "mint", kind: "hermes",
                 connectorName: "Mac mini", remoteRef: "nova", status: .connected, lastSeenAt: .now,
                 isDefault: false, sort: 4),
    ]
    /// `-yuiDemoShared`: an invited client's account. Sam shared Penny and Basil; Scout is paused.
    static let demoShared = [
        YuiAgent(id: "demo-penny", name: "Penny", handle: "penny", color: "peach", kind: "hermes",
                 status: .connected, lastSeenAt: .now, isDefault: false, sort: 0,
                 theme: AgentLook(preset: "candy"), presence: "online", shared: true, sharedBy: "Sam",
                 firstMessage: "Hi Maya! I'm Penny. I keep Sam's schedule. Want to book a time?", clientSafe: true),
        YuiAgent(id: "demo-basil", name: "Basil", handle: "basil", color: "mint", kind: "hermes",
                 status: .connected, lastSeenAt: .now, isDefault: false, sort: 1,
                 theme: AgentLook(preset: "forest"), presence: "online", shared: true, sharedBy: "Sam",
                 firstMessage: "Hey, I'm Basil. Send me a photo of any meal and I'll tell you what's in it.", clientSafe: true),
        YuiAgent(id: "demo-scout", name: "Scout", handle: "scout", color: "sky", kind: "hermes",
                 status: .connected, lastSeenAt: .now, isDefault: false, sort: 2,
                 theme: AgentLook(preset: "ocean"), presence: "paused", shared: true, sharedBy: "Sam", clientSafe: false),
    ]
    static let demoReport = AgentControls(v: 1, sections: ["soul": "rw", "memory": "rwd", "skills": "rwd",
                                                             "schedules": "rwd", "model": "r", "channels": "r"])
    static let demoCode = PairingCode(code: "123456", expiresAt: .now.addingTimeInterval(600))
}
