import Foundation
import Observation
import YuiLines

/// The person's groups, for the agent list (YUI-94).
@Observable @MainActor
final class GroupStore {
    private(set) var groups: [GroupInfo] = []
    private(set) var loaded = false
    /// Words for the person when the last call was refused.
    var error: String?
    /// The group open full screen.
    var openID: String?
    private var client: GroupClient?

    func attach(_ account: Account) {
        guard client == nil else { return }
        client = GroupClient(account: account)
        #if DEBUG
        // -yuiDemoGroup: Yui and Coach in a group that is already open (UI tests, screenshots; use with -yuiDemoAgents).
        if ProcessInfo.processInfo.arguments.contains("-yuiDemoGroup") {
            groups = [GroupInfo(id: "demo-group", title: "Race week", lead: "demo-yui", members: ["demo-yui", "demo-coach"])]
            loaded = true
            openID = "demo-group"
        }
        #endif
    }

    func reset() {
        client = nil
        groups = []
        loaded = false
        openID = nil
        error = nil
    }

    func refresh() async {
        guard let client else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-yuiDemoGroup") { return }
        #endif
        do {
            groups = try await client.list()
            loaded = true
        } catch {
            // A server that has no groups yet, or no network: the list stays as it was.
            loaded = true
        }
    }

    var open: GroupInfo? { groups.first { $0.id == openID } }

    /// Makes a group and opens it. Throws the server's refusal as a `GroupError`.
    @discardableResult
    func create(title: String, lead: String, members: [String]) async throws -> String {
        guard let client else { throw AccountError.signedOut }
        let id = UUID().uuidString.lowercased()
        try await client.create(id: id, title: title, lead: lead, members: members)
        await refresh()
        openID = id
        return id
    }

    func archive(_ id: String) async {
        guard let client else { return }
        do { try await client.archive(id) } catch { self.error = Self.words(error) }
        if openID == id { openID = nil }
        await refresh()
    }

    static func words(_ error: Error) -> String {
        (error as? GroupError)?.spoken ?? "Couldn't do that right now. Try again in a moment."
    }

    func client(_ account: Account) -> GroupClient { GroupClient(account: account) }

    /// The title a new group starts with: the members' names, "Coach, Sage and Quill".
    static func suggestedTitle(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }

    /// A title the server takes: trimmed, 1 to 60 characters. Nil when blank.
    static func validTitle(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(60))
    }
}

/// One open group: its rows, who is working, and what the person says in it.
@Observable @MainActor
final class GroupThread {
    private(set) var info: GroupInfo
    private(set) var rows: [ThreadRow] = []
    private(set) var items: [GroupItem] = []
    private(set) var working: [GroupWorking] = []
    private(set) var loaded = false
    /// What the person just said, until its row comes back from the server.
    private(set) var sending: [GroupItem] = []
    /// A refusal or a failed send, in plain words.
    var notice: String?
    /// The agent the person swiped to reply to: the reply goes to it.
    var replyTarget: String?
    private let client: GroupClient
    private var cursor: String?
    private var poll: Task<Void, Never>?
    private var failed: [String: (words: String, to: [String], echo: String?, photos: [String])] = [:]

    init(info: GroupInfo, client: GroupClient) {
        self.info = info
        self.client = client
    }

    func update(_ fresh: GroupInfo) { info = fresh }

    /// Everything drawn: the server's items, then what was said and has not landed.
    var shown: [GroupItem] { items + sending }

    func start() {
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let busy = self?.working.isEmpty == false || self?.sending.isEmpty == false
                try? await Task.sleep(for: busy ? .milliseconds(1500) : .seconds(4))
            }
        }
    }

    func stopPolling() { poll?.cancel() }

    func refresh() async {
        do {
            let fresh = try await client.rows(thread: info.id, since: cursor.map { YuiTime.before($0, seconds: 5) })
            guard !fresh.isEmpty || !loaded else { loaded = true; return }
            merge(fresh)
            loaded = true
        } catch {
            if !loaded { loaded = true }
        }
    }

    func load(_ fresh: [ThreadRow]) { merge(fresh); loaded = true }

    private func merge(_ fresh: [ThreadRow]) {
        var byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        for r in fresh { byID[r.id] = r }
        // A row's handled_at changes after it lands, so the overlap window refreshes it.
        rows = byID.values.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        cursor = rows.last?.createdAt
        items = GroupRows.items(rows)
        working = GroupRows.working(rows, lead: info.lead)
        let landed = Set(rows.map { $0.id.lowercased() })
        sending.removeAll { landed.contains($0.id.lowercased()) }
    }

    /// Who the words go to: the members @ed, else the one a swipe replied to, else nobody (the lead).
    func addressees(_ text: String, members: [YuiAgent]) -> [String] {
        let named = GroupRows.addressed(text, members: members, handle: \.handle, id: \.id)
        if !named.isEmpty { return named }
        if let replyTarget, members.contains(where: { $0.id == replyTarget }) { return [replyTarget] }
        return []
    }

    func send(_ text: String, members: [YuiAgent]) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        let to = addressees(words, members: members)
        replyTarget = nil
        post(id: UUID().uuidString.lowercased(), words: words, to: to)
    }

    /// Words and photos (the + in the group bar). The photos go up first, then one row carries the bucket paths.
    /// Throws when an upload fails: nothing is added, the person keeps their photos.
    func send(_ text: String, photos: [ComposerPhoto], members: [YuiAgent], account: Account) async throws {
        guard !photos.isEmpty else { send(text, members: members); return }
        let paths = try await YuiMedia(account: account, agentID: info.lead).upload(photos: photos.map(\.jpeg))
        let words = Attachments.body(text: text.trimmingCharacters(in: .whitespacesAndNewlines), photos: paths.count)
        let to = addressees(words, members: members)
        replyTarget = nil
        post(id: UUID().uuidString.lowercased(), words: words, to: to, photos: paths)
    }

    /// A tap or a submit on an agent's screen: that agent's turn, nobody else's.
    func emit(_ e: YLEvent, from agent: String) {
        guard e.relays else { return }
        post(id: UUID().uuidString.lowercased(), words: e.line, to: [agent], echo: e.echo)
    }

    func retry(_ id: String) {
        guard let f = failed[id] else { return }
        sending.removeAll { $0.id == id }
        post(id: id, words: f.words, to: f.to, echo: f.echo, photos: f.photos)
    }

    private func post(id: String, words: String, to: [String], echo: String? = nil, photos: [String] = []) {
        failed[id] = nil
        if echo != nil || !words.hasPrefix("[yui]") { sending.append(.you(id: id, text: echo ?? words, to: to, at: .now)) }
        notice = nil
        let thread = info.id, agent = to.first ?? info.lead
        Task { [weak self] in
            guard let self else { return }
            do {
                try await client.say(id: id, thread: thread, agent: agent, words: words, to: to, echo: echo, photos: photos)
                await refresh()
            } catch {
                sending.removeAll { $0.id == id }
                failed[id] = (words, to, echo, photos)
                notice = GroupStore.words(error)
            }
        }
    }

    /// Let it: send the held ask on a fresh budget.
    func letIt(_ guardID: String) {
        Task { [weak self] in
            guard let self else { return }
            do { try await client.letIt(guard: guardID, thread: info.id, lead: info.lead); await refresh() }
            catch { notice = GroupStore.words(error); await refresh() }
        }
    }

    /// Stop: cancel every handoff not picked up yet.
    func stop() {
        Task { [weak self] in
            guard let self else { return }
            do { try await client.stop(thread: info.id, lead: info.lead); await refresh() }
            catch { notice = GroupStore.words(error) }
        }
    }

    var canStop: Bool { !working.isEmpty }

    /// The guard row still waiting on the person, if any (for the held count).
    var heldGuards: [GroupItem] {
        items.filter { if case .guardAsk(_, _, _, _, _, .held) = $0 { true } else { false } }
    }
}
