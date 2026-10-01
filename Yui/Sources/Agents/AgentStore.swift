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
    /// What it does, as its profile says it (YUI-165): a line under its name, two sentences,
    /// and three things to ask it, each sent as the person's message when tapped.
    /// Nil or empty for an agent that never said (every paired one, for now).
    var tagline: String? = nil
    var about: String? = nil
    var can: [String]? = nil
    /// Its quiet visual, picked for it (YUI-180). Nil from older servers and for agents that never said.
    var visual: VisualDefault? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, handle, color, avatar, kind, status, sort, theme
        case connectorID = "connector_id", connectorName = "connector_name", remoteRef = "remote_ref"
        case lastSeenAt = "last_seen_at", isDefault = "is_default", pushMuted = "push_muted", presence, commands, shared
        case sharedBy = "shared_by", firstMessage = "first_message", clientSafe = "client_safe", shareWhy = "share_why"
        case controls, tagline, about, can, visual
    }

    /// Its tagline, or nil when it has none worth showing.
    var line: String? { tagline.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } }
    /// Up to three starters, blanks dropped.
    var starters: [String] { (can ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(3).map { $0 } }
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

/// One of the crew every person starts with (Yui, Arnold, Basil...), as Add agent
/// offers it (YUI-145). `agentID` is set while it is in the list.
struct CrewStarter: Codable, Identifiable, Hashable, Sendable {
    let base: String
    let name: String
    let role: String
    let color: String
    var agentID: String?
    /// What it says it does (YUI-165), for its page in the first-run picker (YUI-216).
    var tagline: String? = nil
    var about: String? = nil
    var can: [String]? = nil
    var id: String { base }
    enum CodingKeys: String, CodingKey { case base, name, role, color, agentID = "agent_id", tagline, about, can }
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
    /// The crew Add agent offers, one tap each (YUI-145). Nil: this person has no native Yui.
    private(set) var crew: [CrewStarter]?
    /// A new account whose crew is still to pick (YUI-216): the first-run picker is up until it is chosen.
    private(set) var crewPending = false
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
    /// An agent's id from its id or its handle (a hand-off card says `yui://agent/basil`, YUI-144).
    func idFor(_ key: String) -> String {
        let h = key.lowercased()
        return agents.first { $0.id == key || $0.handle == h }?.id ?? key
    }

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
            // -yuiDemoFirstLaunch: a new person's first list, as yui-agents provisions it (YUI-145):
            // Yui and the starter crew, native, above any paired agents (-yuiDemoAgents adds some).
            // -yuiDemoWithout <handle>: that one was removed, so Add agent offers it again ("all": every one).
            if args.contains("-yuiDemoFirstLaunch") || args.contains("-yuiDemoHome") {
                let gone = UserDefaults.standard.string(forKey: "yuiDemoWithout")
                let paired = args.contains("-yuiDemoAgents") ? Self.demoCrew.filter { $0.id != "demo-yui" } : []
                agents = Self.demoStarters.filter { gone != "all" && $0.handle != gone } + paired
                crew = Self.crewOffer(agents)
                // A first launch remembers no agent: it opens on the default, Yui.
                selectedID = nil
                // -yuiDemoPickCrew: a new account before its pick (YUI-216): Yui alone and the picker up.
                if args.contains("-yuiDemoPickCrew") {
                    agents = Self.demoStarters.filter { $0.handle == "yui" }
                    crew = Self.crewOffer(agents)
                    crewPending = true
                }
            }
            // -yuiDemoNative: Yui is a native (hosted) agent, with this month's free web searches used up (YUI-142).
            if args.contains("-yuiDemoNative") {
                agents = agents.map { a in
                    var a = a
                    if a.id == "demo-yui" { a.kind = "hosted" }
                    return a
                }
            }
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
        crew = nil
        crewPending = false
        unshared = []
        notice = nil
    }

    func refresh() async {
        if isDemo { return }
        do {
            let r: ListReply = try await call(["action": "list", "crew_pick": true])
            apply(r.agents)
            firstName = r.firstName
            crew = r.crew
            crewPending = r.crewPending
            loaded = true
            error = nil
            if agents.contains(where: { $0.kind == "hosted" }) { await sendTimeZoneIfNeeded() }
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

    /// Puts one of the crew back in the list (YUI-145). Nothing else in the list changes;
    /// one already there comes back as is. Returns its id, to open its thread.
    func addCrew(_ starter: CrewStarter) async throws -> String {
        if let id = starter.agentID, agents.contains(where: { $0.id == id }) { return id }
        #if DEBUG
        if isDemo {
            guard var a = Self.demoStarters.first(where: { $0.handle == starter.base }) else { throw AccountError.server("invalid_base") }
            let hosted = agents.filter { $0.kind == "hosted" }.map(\.sort)
            a.sort = (hosted.max() ?? -1) + 1
            let at = agents.firstIndex { $0.kind != "hosted" } ?? agents.endIndex
            agents.insert(a, at: at)
            crew = Self.crewOffer(agents)
            return a.id
        }
        #endif
        let r: AgentReply = try await call(["action": "crew_add", "base": starter.base])
        await refresh()
        return r.agent.id
    }

    /// The first-run picker's answer (YUI-216): who joins after Yui, saved on the account so the
    /// picker never returns. `own`: they chose to bring their own agent too.
    func chooseCrew(_ bases: [String], own: Bool = false) async throws {
        #if DEBUG
        if isDemo {
            for s in crew ?? [] where bases.contains(s.base) && s.agentID == nil { _ = try await addCrew(s) }
            crewPending = false
            return
        }
        #endif
        let _: ChooseReply = try await call(["action": "crew_choose", "bases": bases, "own": own])
        crewPending = false
        await refresh()
    }

    /// Everyone in the crew who isn't in the list, in one tap (Chris, 2026-09-27: "either have
    /// all these agents or ... any number of them"). Nothing already in the list changes.
    func addAllCrew() async throws {
        #if DEBUG
        if isDemo {
            for s in crew ?? [] where !(s.agentID.map { id in agents.contains { $0.id == id } } ?? false) {
                _ = try await addCrew(s)
            }
            return
        }
        #endif
        let _: AddAllReply = try await call(["action": "crew_add_all"])
        await refresh()
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
        var crew: [CrewStarter]? = nil
        var crewPending = false
        enum CodingKeys: String, CodingKey { case agents, firstName = "first_name", crew, crewPending = "crew_pending" }
    }
    private struct CreateReply: Decodable { let agent: YuiAgent; let pairing: PairingCode? }
    private struct AgentReply: Decodable { let agent: YuiAgent }
    private struct AddAllReply: Decodable { let added: [String] }
    private struct ChooseReply: Decodable { let added: [String] }
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
        req.timeoutInterval = 15
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
    /// `-yuiDemoFirstLaunch`: Yui and the crew, native, the way yui_native_provision makes them
    /// (runtime/profiles, Yui first and the default). Each thread opens on its first message.
    static let demoStarters: [YuiAgent] = [
        ("yui", "Yui", "brand"), ("arnold", "Arnold", "butter"), ("basil", "Basil", "mint"),
        ("gouda", "Gouda", "lavender"), ("penny", "Penny", "butter"), ("quill", "Quill", "lavender"),
    ].enumerated().map { i, s in
        YuiAgent(id: "demo-\(s.0)", name: s.1, handle: s.0, color: s.2, avatar: s.0 == "yui" ? "yui" : nil, kind: "hosted",
                 connectorName: "Yui", remoteRef: s.0, status: .connected, lastSeenAt: .now,
                 isDefault: s.0 == "yui", sort: i - 7, presence: "online", controls: demoNativeReport,
                 tagline: demoSaid[s.0]?.tagline, about: demoSaid[s.0]?.about, can: demoSaid[s.0]?.can)
    }
    /// What each starter says it does, verbatim from runtime/profiles/<name>/profile.json
    /// (FirstLaunchDemoTests checks they still match).
    static let demoSaid: [String: (tagline: String, about: String, can: [String])] = [
        "yui": ("Ask anything, or make a new agent",
                "Yui answers anything and knows the whole crew. Ask for a helper that isn't here yet and Yui makes it.",
                ["Make me a new agent", "Who should I talk to?", "What can you do?"]),
        "arnold": ("Workouts built around your week and body",
                   "A training week around your days, your gear and anything that hurts. Timers run on screen and every set gets logged.",
                   ["Start today's workout", "Log today's workout", "Build my training week"]),
        "basil": ("Eat better without counting everything",
                  "Plans your week of meals around your goal and what you can't eat, with the grocery list by aisle. Snap a plate and today's macros fill in.",
                  ["Plan my meals", "What should I eat tonight?", "Add oat milk to my groceries"]),
        "gouda": ("Beats, chords and practice, right on screen",
                  "Learn a song on chord buttons with the click counting you in, slow it down, loop the hard bar. Beats you save by name, and a practice log with a streak.",
                  ["Learn a song", "Make a beat", "Log practice"]),
        "penny": ("Get your week out of your head",
                  "Lists, plans and timelines for everything on your plate. Say what's going on and get back a week you can see.",
                  ["Plan my week", "What's next today?", "Evening review"]),
        "quill": ("Learn anything fast, then get quizzed",
                  "Five minute lessons with pictures, math and charts, one idea per page. A quick quiz at the end makes it stick.",
                  ["Teach me something new", "Quiz me on what I learned", "Walk me through a math problem"]),
    ]
    static let demoRoles = ["yui": "Helper and maker", "arnold": "Trainer", "basil": "Nutritionist",
                            "gouda": "Musician", "penny": "Planner", "quill": "Study buddy"]
    /// What yui-agents `list` says about the crew for this list.
    static func crewOffer(_ agents: [YuiAgent]) -> [CrewStarter] {
        demoStarters.map { s in
            CrewStarter(base: s.handle, name: s.name, role: demoRoles[s.handle] ?? "", color: s.color,
                        agentID: agents.first { $0.kind == "hosted" && $0.handle == s.handle }?.id,
                        tagline: demoSaid[s.handle]?.tagline, about: demoSaid[s.handle]?.about, can: demoSaid[s.handle]?.can)
        }
    }
    /// Each starter's first message, verbatim from runtime/profiles/<name>/first.yui
    /// (FirstLaunchDemoTests checks they still match).
    static let demoFirst: [String: String] = [
        "yui": "Hi, I'm Yui. Your crew is here: Arnold trains, Basil feeds you, Gouda makes music, Penny keeps your lists and Quill helps you study. Or ask me anything.\n```yui\nchoose \"Where do you want to start?\" \"Get fit\"|\"Eat better\"|\"Make music\"|\"Plan my week\"|\"Learn something\" +other\n```",
        "arnold": "Arnold here. Five taps and you have a week you'll actually do. Anything hurting or any health condition I should plan around? Check with your doctor before starting if so.\n```yui\nplan@first \"Your first plan\" submit=\"Build my week\"\nchoose@goal \"What are we training for?\" \"Lift heavy\"|\"Lift and cardio\"|\"Mostly cardio\"|\"Just move more\"|\"Not sure\"\nchoose@days \"How many days a week?\" 2|3|4|5|6|\"Not sure\"\nchoose@time \"How long per session?\" \"30 min\"|\"45 min\"|\"60 min\"|\"Not sure\"\npick@gear \"What do you have?\" \"Just me\"|Bands|Dumbbells|Barbell|\"A gym\"\nchoose@level \"How much have you lifted?\" \"New to lifting\"|\"Some experience\"|\"Lifted for years\"|\"Not sure\" body=\"Heavy lifters finish the last set of each lift at failure with a safe stop. New lifters stop well short.\"\nend\ncard@first-skip \"Not now\" \"Keep the starter week. Build yours any time from This week.\" cta=\"Skip for now\"\n```",
        "basil": "I'm Basil. Five taps and you have a week of meals. Not sure and Skip are always there. On medication or managing a condition? Check with your doctor before big changes.\n```yui\nplan@first \"Your first meal plan\" submit=\"Plan my week\"\nchoose@goal \"What's the goal?\" \"Eat better\"|\"Lose weight\"|\"Build muscle\"|\"Save time\"|\"Not sure\"|\"Skip\"\npick@days \"Which days should I plan?\" \"Mon\"|\"Tue\"|\"Wed\"|\"Thu\"|\"Fri\"|\"Sat\"|\"Sun\"|\"Not sure\"|\"Skip\"\nchoose@meals \"How many meals a day?\" \"2\"|\"3\"|\"3 and a snack\"|\"4 or more\"|\"Not sure\"|\"Skip\"\npick@avoid \"What should I leave out? Allergies and conditions count.\" \"Meat\"|\"Fish\"|\"Dairy\"|\"Gluten\"|\"Nuts\"|\"Eggs\"|\"Nothing\"|\"Not sure\"|\"Skip\" +other\nchoose@cook \"How long can you cook?\" \"15 minutes\"|\"30 minutes\"|\"An hour\"|\"I like a project\"|\"Not sure\"|\"Skip\"\nend\n```",
        "gouda": "Gouda here. Four taps and you have a practice plan. Not sure and Skip are always there.\n```yui\nplan@first \"Your first practice plan\" submit=\"Build my practice\"\nchoose@instrument \"What do you play?\" \"Guitar\"|\"Piano\"|\"Drums\"|\"Bass\"|\"Voice\"|\"Not yet\"|\"Not sure\"|\"Skip\"\nchoose@level \"How would you rate yourself?\" \"Brand new\"|\"Know a few things\"|\"Getting there\"|\"Pretty good\"|\"Not sure\"|\"Skip\"\nchoose@minutes \"Minutes a day?\" \"10\"|\"20\"|\"30\"|\"An hour\"|\"Not sure\"|\"Skip\"\npick@want \"What do you want to play?\" \"Songs\"|\"Scales\"|\"Chords\"|\"Make my own\"|\"Play by ear\"|\"Not sure\"|\"Skip\"\nend\n```",
        "penny": "Penny here. Three taps and you have a planning routine. Not sure and Skip are always there.\n```yui\nplan@first \"Your first routine\" submit=\"Set my routine\"\npick@busy \"Which days are packed?\" \"Mon\"|\"Tue\"|\"Wed\"|\"Thu\"|\"Fri\"|\"Sat\"|\"Sun\"|\"None\"|\"Not sure\"|\"Skip\"\nchoose@plan \"When do you plan?\" \"Sunday night\"|\"Monday morning\"|\"Each morning\"|\"Each night\"|\"Not sure\"|\"Skip\"\nchoose@remind \"How do you want reminders?\" \"At the time\"|\"10 minutes before\"|\"The night before\"|\"None\"|\"Not sure\"|\"Skip\"\nend\n```",
        "quill": "Quill here. Three taps and you have a study plan. Not sure and Skip are always there.\n```yui\nplan@first \"Your first study plan\" submit=\"Build my plan\"\nchoose@topic \"What are you learning?\" \"A language\"|\"A school subject\"|\"A skill for work\"|\"Something for fun\"|\"Not sure\"|\"Skip\" +other\nchoose@minutes \"How many minutes a day?\" \"10 minutes\"|\"20 minutes\"|\"30 minutes\"|\"An hour\"|\"Not sure\"|\"Skip\"\nchoose@quiz \"How do you like to be quizzed?\" \"Flash cards\"|\"Multiple choice\"|\"Write it out\"|\"Out loud\"|\"Not sure\"|\"Skip\"\nend\n```",
    ]
    /// Yui's hello after the pick, as crewHello (runtime/src/starters.ts) writes it: only who joined.
    static func demoHello(_ bases: [String]) -> String {
        let does = [("arnold", "Arnold trains", "Get fit"), ("basil", "Basil feeds you", "Eat better"),
                    ("gouda", "Gouda makes music", "Make music"), ("penny", "Penny keeps your lists", "Plan my week"),
                    ("quill", "Quill helps you study", "Learn something")].filter { bases.contains($0.0) }
        if does.isEmpty {
            return "Hi, I'm Yui. It's just us for now. Ask me anything, or I'll make you a helper.\n```yui\nchoose \"What should we do first?\" \"Make me a helper\"|\"What can you do?\" +other\n```"
        }
        let names = does.map(\.1)
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        let opts = does.map { "\"\($0.2)\"" }.joined(separator: "|")
        return "Hi, I'm Yui. Your crew is here: \(list). Or ask me anything.\n```yui\nchoose \"Where do you want to start?\" \(opts) +other\n```"
    }
    /// Each starter's home (YUI-168) as yui-agents writes it into the thread: runtime/profiles/<name>/home.yui
    /// less its comments, with the demo crew's ids filled in (FirstLaunchDemoTests checks they still match).
    static let demoHome: [String: String] = [
        "yui": "```yui\nmenu shortcut@new \"What's new\" say=\"What's new in Yui?\"\nmenu shortcut@add \"Add an agent\" say=\"Make me a new agent: \"\n>2\ncard@crew-arnold Arnold \"Workouts built around your week and body\" sub=Trainer url=yui://agent/demo-arnold/thread cta=Open\ncard@crew-basil Basil \"Eat better without counting everything\" sub=Nutritionist url=yui://agent/demo-basil/thread cta=Open\ncard@crew-gouda Gouda \"Beats, chords and practice, right on screen\" sub=Musician url=yui://agent/demo-gouda/thread cta=Open\ncard@crew-penny Penny \"Get your week out of your head\" sub=Planner url=yui://agent/demo-penny/thread cta=Open\ncard@crew-quill Quill \"Learn anything fast, then get quizzed\" sub=\"Study buddy\" url=yui://agent/demo-quill/thread cta=Open\nsave your crew\n```",
        "arnold": "```yui\nmenu shortcut@progress \"Progress\" show=\"progress\"\nmenu shortcut@log \"Log a workout\" say=\"Log today's workout\"\nmenu shortcut@split \"My split\" show=\"this week\"\nmenu shortcut@workout \"Start a workout\" say=\"Start today's workout\"\n>2\nstat@week-done \"0 of 5\" \"Workouts this week\" sub=\"Build your split and this fills in\"\nlist@days title=\"This week\" \"Mon Full body A\" \"Tue Easy cardio\" \"Wed Full body B\" \"Fri Full body A\" \"Sat Long walk\"\nchoose@edit-day \"Change a day\" Mon|Tue|Wed|Thu|Fri|Sat|Sun body=\"Tap a day to change what it trains.\"\ncard@split \"Make it yours\" \"Your days, your split, your gear. This week fills in from it.\" cta=\"Build my split\"\nsave this week\n>3\ncard@today \"Today's workout\" \"Full body A to start. About 40 minutes.\" sub=\"Starter week\" cta=\"Start\"\nlist@sets title=\"Full body A\" \"Goblet squat 3x10\" \"Push-up 3x8\" \"Dumbbell row 3x10\" \"Plank 3x30s\" +check\nsave today\n>4\nstat@streak \"0 weeks\" \"Streak\" sub=\"Finish a workout and this starts\"\nstat@best \"None yet\" \"Best set\" sub=\"Your heaviest set shows here\"\ncard@lifts \"Your lifts\" \"Every lift you log gets its own chart here.\"\nsave progress\n```",
        "basil": "```yui\nmenu shortcut@groceries \"Grocery list\" show=groceries\nmenu shortcut@week \"This week\" show=\"this week\"\nmenu shortcut@log \"Log a meal\" say=\"Log a meal: \"\nmenu shortcut@plan \"Plan my meals\" say=\"Plan my meals\"\n>2\nstat@kcal 0kcal \"Calories today\" sub=\"of 2,100. Log a meal to start.\"\nchart@macros bar \"Macros vs goal\" x=Protein|Carbs|Fat y=0|0|0 y2=140|210|70 names=Today|Goal unit=g\ncard@next-meal \"No plan yet\" \"Tell me what you like and I'll plan your week.\" cta=\"Plan my meals\"\nchoose@eaten \"Tap a meal to fix it\" \"Log a meal\" body=\"Nothing logged yet today.\"\nsave today\n>3\ncard@week-plan \"This week's meals\" \"Tell me what you like and I'll plan your week, with a grocery list.\" cta=\"Plan my meals\"\nsave this week\n>4\nstat@groc-left \"6 to get\" \"Grocery list\" sub=\"Plan your meals and this fills in\"\nlist@aisle-produce title=\"Produce\" \"Spinach\"|\"Berries\" +check\nlist@aisle-meat-and-fish title=\"Meat and fish\" \"Chicken thighs\" +check\nlist@aisle-dairy-and-eggs title=\"Dairy and eggs\" \"Greek yogurt\"|\"Eggs\" +check\nlist@aisle-pantry title=\"Pantry\" \"Rice\" +check\ncard@groc-add \"Need something else?\" \"Say it or type it, like: add oat milk to my groceries.\" cta=\"Add to the list\"\nsave groceries\n```",
        "gouda": "```yui\nmenu shortcut@tune \"Tune up\" show=tuner\nmenu shortcut@jam \"Jam\" say=\"Make me a beat to jam on\"\nmenu shortcut@log \"Log practice\" say=\"Log practice\"\nmenu shortcut@learn \"Learn a song\" say=\"Learn a song\"\n>2\nloop@looper 92 \"Lazy Sunday\" p=x...x...|..x...x.|........|x.x.x.x. +inline\nchoose@sessions \"Open a beat\" \"Lazy Sunday\"|\"Boom bap\"|\"Four on the floor\"|\"Rock backbeat\"|\"One drop\" body=\"Stop the looper and your changes go to Gouda.\"\nsave looper\n>3\ncard@lesson \"Learn a song\" \"Pick a song or paste its chords. The click counts you in and your keys stay in key.\" cta=\"Learn a song\"\nchords@chords C I-V-vi-IV \"Chords\" +inline\nmetronome@click 90 \"Click\"\nsave chords\n>4\nkeys@keys C major \"Keys\" +inline\nchoose@scale \"Scale\" \"Major\"|\"Minor\"|\"Pentatonic\"|\"Blues\" body=\"C major. Keys outside it stay quiet.\"\nsave keys\n>5\nstat@streak \"0 days\" \"Streak\" sub=\"Practice today and this starts.\"\nstat@week-min \"0 min\" \"This week\" sub=\"The click logs itself after 10 seconds\"\nchart@practice-chart bar \"Minutes a day\" x=Mon|Tue|Wed|Thu|Fri|Sat|Sun y=0|0|0|0|0|0|0 unit=min\ncard@next-up \"Next: ten minutes\" \"Pick a song on Chords and play along with the click. It all counts toward your streak.\" cta=\"Log practice\"\nlist@recent title=\"Lately\" \"Nothing logged yet\"\nsave practice\n>6\ntuner@tuner guitar +inline\nsave tuner\n```",
        "penny": "```yui\nmenu shortcut@review \"Evening review\" say=\"Evening review\"\nmenu shortcut@next \"What's next?\" say=\"What's next today?\"\nmenu shortcut@todo \"Add a to-do\" say=\"Add a to-do: \"\nmenu shortcut@plan \"Plan my week\" say=\"Plan my week\"\n>2\ncard@next-task \"Nothing on today yet\" \"Tell me what's on your mind and I'll sort your week into days.\" sub=\"Up next\" cta=\"Plan my week\"\nlist@today title=Today \"Nothing on today\" +check\ncard@wrap \"Evening review\" \"Two minutes at the end of the day: done, tomorrow or drop.\" cta=\"Wrap up the day\"\nsave today\n>3\ntimeline@week \"This week\" mark=Today fold=12\nnext@wk-t1 \"Tell Penny what's on your mind this week\" at=\"Any day\" key=t1\ncard@week-move \"Move a task\" \"Drag with Edit order, or pick a task and a day.\" cta=\"Move a task\"\ncard@week-plan \"Plan my week\" \"Talk it out: everything on your plate. I'll sort it into days.\" cta=\"Plan my week\"\nsave this week\n```",
        "quill": "```yui\nmenu shortcut@next \"What's due?\" say=\"What should I review next?\"\nmenu shortcut@problem \"Walk me through a problem\" say=\"Walk me through a problem\"\nmenu shortcut@learn \"Learn something new\" say=\"Teach me something new\"\nmenu shortcut@review \"Review my cards\" say=\"Review my cards\"\n>2\ncard@studying \"World capitals\" \"8 cards. 8 due today.\" sub=\"Geography\" cta=\"Review now\"\nlist@decks title=\"Your decks\" \"World capitals, 8 cards\"\ncard@learn-new \"Learn something new\" \"A topic, how long you have, what you know. A short lesson, then a quiz.\" cta=\"Learn a topic\"\ncard@walk \"Stuck on a problem?\" \"I'll break it into steps. You answer each one before the next.\" cta=\"Walk me through it\"\nsave studying\n>3\nstat@due 8 \"Cards due today\" sub=\"World capitals\"\ncard@review-start \"Review 8 cards\" \"Think of the answer, then tap again, hard, good or easy.\" cta=\"Start review\"\nsave next review\n>4\nstat@streak 0 \"Day streak\" sub=\"Review today to start one\"\nchart@studied bar \"Cards reviewed\" x=Mon|Tue|Wed|Thu|Fri|Sat|Sun y=0|0|0|0|0|0|0\nstat@learned 0 \"Cards learned\" sub=\"of 8 cards, box 4 or higher\"\nstat@last-quiz \"None\" \"Last quiz\" sub=\"Finish a lesson's quiz\"\nsave progress\n```",
    ]
    static let demoNativeReport = AgentControls(v: 1, sections: ["soul": "rw", "memory": "rwd", "schedules": "rwd", "model": "r"])
    static let demoReport = AgentControls(v: 1, sections: ["soul": "rw", "memory": "rwd", "skills": "rwd",
                                                             "schedules": "rwd", "model": "r", "channels": "r"])
    static let demoCode = PairingCode(code: "123456", expiresAt: .now.addingTimeInterval(600))
}

// MARK: Native Yui (NATIVE-1, yuigui spec/NATIVE.md)

/// What `yui-native` says about this person: their own model key (never the key
/// itself), the providers it takes, and this month's free turns.
struct NativeStatus: Decodable, Equatable, Sendable {
    struct Key: Decodable, Equatable, Sendable {
        let provider: String
        let model: String?
        let hint: String
    }
    struct Provider: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let label: String
        let needsModel: Bool
        /// Where this provider makes a key, and one line when a chat plan can't pay for it (older servers leave both out).
        var keyUrl: String? = nil
        var plan: String? = nil
    }
    struct Turns: Decodable, Equatable, Sendable {
        let used: Int
        let limit: Int
    }
    /// Web search (YUI-142): free lookups this month on Yui's Firecrawl key, or their own key (last four only).
    struct Search: Decodable, Equatable, Sendable {
        struct Key: Decodable, Equatable, Sendable { let hint: String }
        let used: Int
        let limit: Int
        let key: Key?
    }
    let key: Key?
    let providers: [Provider]
    let turns: Turns
    let search: Search? // older servers leave it out
    /// Every key they hold, one per provider, and each agent's pick: "yui", a provider id, or "default" (follow `key`).
    /// Older servers leave both out (YUI-139 step 2g).
    var keys: [Key]? = nil
    var agentKeys: [String: String]? = nil

    /// What one agent runs on: "yui" or a provider id. `reported` is the Controls answer's `key`, used when status has no pick.
    func runsOn(_ agentID: String, reported: String? = nil) -> String {
        let pick = agentKeys?[agentID] ?? reported ?? "default"
        return pick == "default" ? (key?.provider ?? "yui") : pick
    }

    func holds(_ provider: String) -> Bool { (keys ?? key.map { [$0] } ?? []).contains { $0.provider == provider } }
    func held(_ provider: String) -> Key? { (keys ?? key.map { [$0] } ?? []).first { $0.provider == provider } }
}

/// The three-way pick on Controls > Model: Yui's key, Claude, ChatGPT, plus any other provider they hold a key for.
struct KeyChoice: Equatable, Identifiable, Sendable {
    let id: String   // "yui" or a provider id
    let label: String
    let hint: String? // last four of the key, nil when there is none yet
    var held: Bool { id == "yui" || hint != nil }

    static func choices(_ s: NativeStatus) -> [KeyChoice] {
        func label(_ id: String) -> String { s.providers.first { $0.id == id }?.label ?? ["anthropic": "Claude", "openai": "ChatGPT"][id] ?? id }
        var ids = ["anthropic", "openai"]
        for k in s.keys ?? s.key.map({ [$0] }) ?? [] where !ids.contains(k.provider) { ids.append(k.provider) }
        return [KeyChoice(id: "yui", label: "Yui's key", hint: nil)]
            + ids.map { KeyChoice(id: $0, label: label($0), hint: s.held($0)?.hint) }
    }
}

/// A refusal from `yui-native`, in its own words ("the provider turned this key down").
struct NativeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension AgentStore {
    func nativeStatus() async throws -> NativeStatus {
        #if DEBUG
        if isDemo, ProcessInfo.processInfo.arguments.contains("-yuiDemoNative") { return Self.demoStatus }
        #endif
        return try await nativeCall(["action": "status"])
    }

    #if DEBUG
    /// The demo's own keys and picks, so the pick can be tapped through with no network (-yuiDemoNative).
    /// MainActor like the store; a key the person "adds" here is only kept for the run.
    static var demoHeld: [NativeStatus.Key] = []
    static var demoPicks: [String: String] = [:]
    static var demoStatus: NativeStatus {
        var s = demoNative
        s.keys = demoHeld
        s.agentKeys = demoPicks
        return s
    }

    static let demoNative = NativeStatus(key: nil, providers: [
        .init(id: "openrouter", label: "OpenRouter", needsModel: false),
        .init(id: "anthropic", label: "Claude", needsModel: false, keyUrl: "https://console.anthropic.com/settings/keys",
              plan: "A Claude Pro or Max plan can't pay for another app. Only an API key can."),
        .init(id: "openai", label: "ChatGPT", needsModel: false, keyUrl: "https://platform.openai.com/api-keys",
              plan: "A ChatGPT Plus or Pro plan can't pay for another app. Only an API key can."),
    ],
                                         turns: .init(used: 31, limit: 100), search: .init(used: 50, limit: 50, key: nil))
    #endif

    /// Checked with the provider first; a key that doesn't work is never kept.
    /// With `agentID` the key is kept for that one agent (it switches to it, the rest keep their default).
    func setModelKey(provider: String, key: String, model: String?, baseURL: String?, agentID: String? = nil) async throws {
        #if DEBUG
        if demoNative(), let agentID {
            Self.demoHeld.removeAll { $0.provider == provider }
            Self.demoHeld.append(.init(provider: provider, model: nil, hint: String(key.suffix(4))))
            Self.demoPicks[agentID] = provider
            return
        }
        #endif
        let _: NativeOK = try await nativeCall(Self.keySetBody(provider: provider, key: key, model: model, baseURL: baseURL, agentID: agentID))
    }

    func removeModelKey(provider: String? = nil) async throws {
        let _: NativeOK = try await nativeCall(Self.keyRemoveBody(provider: provider))
    }

    /// Which key one agent runs on: "yui", a provider they hold a key for, or "default" (follow their default key).
    func setAgentKey(agentID: String, use: String) async throws {
        #if DEBUG
        if demoNative() { Self.demoPicks[agentID] = use; return }
        #endif
        let _: NativeOK = try await nativeCall(Self.agentKeyBody(agentID: agentID, use: use))
    }

    #if DEBUG
    private func demoNative() -> Bool { isDemo && ProcessInfo.processInfo.arguments.contains("-yuiDemoNative") }
    #endif

    // The payloads yui-native takes (one place, so a test can hold them to the server's shape).
    static func keySetBody(provider: String, key: String, model: String?, baseURL: String?, agentID: String? = nil) -> [String: Any] {
        var body: [String: Any] = ["action": "key_set", "provider": provider, "key": key]
        if let model, !model.isEmpty { body["model"] = model }
        if let baseURL, !baseURL.isEmpty { body["base_url"] = baseURL }
        if let agentID { body["agent_id"] = agentID }
        return body
    }

    static func keyRemoveBody(provider: String? = nil) -> [String: Any] {
        var body: [String: Any] = ["action": "key_remove"]
        if let provider { body["provider"] = provider }
        return body
    }

    static func agentKeyBody(agentID: String, use: String) -> [String: Any] {
        ["action": "agent_key", "agent_id": agentID, "use": use]
    }

    /// Their own Firecrawl key: checked with Firecrawl first, kept in Yui's vault, lifts the free search cap.
    func setSearchKey(_ key: String) async throws {
        let _: NativeOK = try await nativeCall(["action": "search_key_set", "key": key])
    }

    func removeSearchKey() async throws {
        let _: NativeOK = try await nativeCall(["action": "search_key_remove"])
    }

    /// Native agents set check-ins in the person's own time. Sent when it changes.
    func sendTimeZoneIfNeeded() async {
        if isDemo { return }
        let tz = TimeZone.current.identifier
        guard UserDefaults.standard.string(forKey: "nativeTimeZoneSent") != tz else { return }
        do {
            let _: NativeOK = try await nativeCall(["action": "timezone", "tz": tz])
            UserDefaults.standard.set(tz, forKey: "nativeTimeZoneSent")
        } catch {}
    }

    private struct NativeOK: Decodable { let ok: Bool }
    private struct NativeRefusal: Decodable { let error: String; let message: String? }

    private func nativeCall<T: Decodable>(_ body: [String: Any]) async throws -> T {
        let payload = try JSONSerialization.data(withJSONObject: body)
        let token = try await account.validAccessToken()
        var req = URLRequest(url: YuiBackend.function("yui-native"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(YuiBackend.publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = payload
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let r = try? JSONDecoder().decode(NativeRefusal.self, from: data)
            throw NativeError(message: r?.message ?? Self.nativeWords[r?.error ?? ""] ?? "Yui's server couldn't do that. Try again in a moment.")
        }
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(T.self, from: data)
    }

    private static let nativeWords = [
        "invalid_key": "That doesn't look like a key.",
        "invalid_base_url": "The server address needs to start with https://.",
        "model_required": "Add the model name this provider should run.",
        "unknown_provider": "Pick a provider.",
        "no_key": "Add a key for that provider first.",
        "not_found": "Yui couldn't find that agent.",
    ]
}
