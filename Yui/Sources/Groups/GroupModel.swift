import Foundation
import YuiLines

/// A group thread: two or more of the person's agents in one conversation (YUI-94).
/// Spec: yuigui/spec/GROUPS.md. The rows live in `yui_threads` and `yui_thread_members`.
struct GroupInfo: Identifiable, Equatable, Decodable, Sendable {
    let id: String
    var title: String
    /// The agent that answers anything not addressed.
    var lead: String
    var maxHops: Int
    var maxTurns: Int
    var archivedAt: String?
    var createdAt: String?
    /// Agent ids that are in the group now (left ones are dropped), lead included.
    var members: [String]

    enum CodingKeys: String, CodingKey {
        case id, title, lead, members = "yui_thread_members"
        case maxHops = "max_hops", maxTurns = "max_turns", archivedAt = "archived_at", createdAt = "created_at"
    }

    private struct Member: Decodable { let agent_id: String; let left_at: String? }

    init(id: String, title: String, lead: String, maxHops: Int = 3, maxTurns: Int = 8, members: [String]) {
        self.id = id; self.title = title; self.lead = lead
        self.maxHops = maxHops; self.maxTurns = maxTurns; self.members = members
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        lead = try c.decode(String.self, forKey: .lead)
        maxHops = try c.decodeIfPresent(Int.self, forKey: .maxHops) ?? 3
        maxTurns = try c.decodeIfPresent(Int.self, forKey: .maxTurns) ?? 8
        archivedAt = try c.decodeIfPresent(String.self, forKey: .archivedAt)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        let rows = try c.decodeIfPresent([Member].self, forKey: .members) ?? []
        members = rows.filter { $0.left_at == nil }.map(\.agent_id)
    }

    /// The members in the order the header draws them: the lead first, then the rest as given.
    func ordered<A>(_ agents: [A], id of: (A) -> String) -> [A] {
        let mine = agents.filter { members.contains(of($0)) }
        return mine.filter { of($0) == lead } + mine.filter { of($0) != lead }
    }
}

/// What Yui's server can refuse a group call with (PostgREST `message`).
enum GroupError: Error, Equatable {
    case updateNeeded, limitReached, notFound, archived, notMember, tooMany, usesTo, guardGone
    case leadNotMember, leadCannotLeave
    case other(String)

    init(message: String) {
        switch message {
        case "update_needed": self = .updateNeeded
        case "limit_reached": self = .limitReached
        case "group_not_found": self = .notFound
        case "group_archived": self = .archived
        case "group_agent_not_member": self = .notMember
        case "group_too_many": self = .tooMany
        case "group_uses_to": self = .usesTo
        case "group_guard_gone": self = .guardGone
        case "group_lead_not_member": self = .leadNotMember
        case "group_lead_cannot_leave": self = .leadCannotLeave
        default: self = .other(message)
        }
    }

    /// Plain words for the person.
    var spoken: String {
        switch self {
        case .updateNeeded: "Groups need the latest Yui. Update the app to start one."
        case .limitReached: "That group is full, or you have the most groups you can. Archive one first."
        case .notFound: "That group is gone."
        case .archived: "That group is archived. Nothing more goes in it."
        case .notMember: "That agent isn't in this group."
        case .tooMany: "Ask up to three agents at once."
        case .usesTo: "That message can't be a mention and a group message at once."
        case .guardGone: "That ask is already handled."
        case .leadNotMember: "The lead has to be in the group."
        case .leadCannotLeave: "The lead can't leave. Make someone else lead first."
        case .other: "Couldn't do that right now. Try again in a moment."
        }
    }
}

/// One thing the group thread draws, in order.
enum GroupItem: Identifiable, Equatable {
    /// The person's words.
    case you(id: String, text: String, to: [String], at: Date)
    /// An agent's answer, in its look.
    case agent(id: String, agent: String, text: String, at: Date)
    /// "Coach asked Sage" and one line of the ask. `msg` is the bubble that asked.
    case handoff(id: String, from: String, to: String, ask: String, msg: String?, cancelled: Bool)
    /// A held ask: Let it or Stop here.
    case guardAsk(id: String, asker: String, to: String, toName: String, text: String, state: GuardState)
    /// A quiet line about an agent: asleep, offline, stopped.
    case status(id: String, about: String, text: String)

    enum GuardState: String, Equatable { case held, continued, stopped, gone }

    var id: String {
        switch self {
        case .you(let id, _, _, _), .agent(let id, _, _, _), .handoff(let id, _, _, _, _, _),
             .guardAsk(let id, _, _, _, _, _), .status(let id, _, _): id
        }
    }
}

/// An agent working on a turn: its newest unhandled row.
struct GroupWorking: Equatable {
    let agent: String
    let since: Date
    var pickedUp: Date?
    var doing: YLDoing?
}

/// Rows in, things to draw out. Pure, so the mapping is unit tested.
@MainActor
enum GroupRows {
    /// The thread's rows, as drawn. Hidden: a copy for a second addressee, Let it and Stop rows,
    /// settings traffic. The person's rows draw `meta.group.words`, never the body (the body has the quote).
    static func items(_ rows: [ThreadRow]) -> [GroupItem] {
        rows.compactMap { item($0) }
    }

    static func item(_ row: ThreadRow) -> GroupItem? {
        guard row.kind != "control" else { return nil }
        let g = row.meta?["group"]
        if g?["copy_of"] != nil || g?["control"] != nil { return nil }
        let at = YuiTime.date(row.createdAt) ?? .now
        if row.sender == "user" { return userItem(row, g, at: at) }
        if let guardMeta = g?["guard"], let to = guardMeta["to"]?.string {
            return .guardAsk(id: row.id, asker: row.agentID ?? "", to: to, toName: guardMeta["to_name"]?.string ?? "",
                             text: row.body,
                             state: GroupItem.GuardState(rawValue: guardMeta["state"]?.string ?? "") ?? .held)
        }
        if g?["status"] != nil {
            return .status(id: row.id, about: g?["about"]?.string ?? row.agentID ?? "", text: row.body)
        }
        guard let agent = row.agentID else { return nil }
        return .agent(id: row.id, agent: agent, text: row.body, at: at)
    }

    private static func userItem(_ row: ThreadRow, _ g: YLValue?, at: Date) -> GroupItem? {
        if let from = g?["from"]?.string {
            return .handoff(id: row.id, from: from, to: row.agentID ?? "", ask: ask(in: row.body),
                            msg: g?["msg"]?.string, cancelled: g?["cancelled"]?.bool ?? false)
        }
        let words = g?["words"]?.string ?? plain(row.body)
        let to = g?["to"]?.array?.compactMap(\.string) ?? []
        // A tap on an agent's screen goes as its event line: the person sees what they picked, or nothing.
        if words.hasPrefix("[yui]") {
            guard let echo = row.meta?["echo"]?.string, !echo.isEmpty else { return nil }
            return .you(id: row.id, text: echo, to: to, at: at)
        }
        return .you(id: row.id, text: words, to: to, at: at)
    }

    /// The words of a `[yui] group ...` row: no header line, no quoted context.
    static func plain(_ body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("[yui]") && !$0.hasPrefix(">") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One line of a handoff ask: what the asking agent said after the @.
    static func ask(in body: String) -> String {
        let line = plain(body).split(separator: "\n").last.map(String.init) ?? ""
        let words = line.replacingOccurrences(of: #"^(@\w+\s*)+"#, with: "", options: .regularExpression)
        return words.isEmpty ? line : words
    }

    /// Who is working: every agent with a person row (a message, a copy, a handoff) it has not handled
    /// yet, newest unhandled first. A cancelled handoff is handled. Lead first, then the order they were asked.
    static func working(_ rows: [ThreadRow], lead: String?) -> [GroupWorking] {
        var out: [GroupWorking] = []
        for row in rows where row.sender == "user" && row.kind != "control" && row.handledAt == nil {
            guard let agent = row.agentID, row.meta?["group"]?["control"] == nil,
                  row.meta?["group"]?["cancelled"]?.bool != true else { continue }
            if out.contains(where: { $0.agent == agent }) { continue }
            out.append(GroupWorking(agent: agent, since: YuiTime.date(row.createdAt) ?? .now,
                                    pickedUp: row.deliveredAt.flatMap(YuiTime.date), doing: ChatStore.doing(row.doing)))
        }
        return out.filter { $0.agent == lead } + out.filter { $0.agent != lead }
    }

    /// `@Coach @Sage plan Saturday`: the member ids a message addresses, in order, three at most.
    /// A word that is not a member's handle is not an @.
    static func addressed<A>(_ text: String, members: [A], handle: (A) -> String, id: (A) -> String) -> [String] {
        var out: [String] = []
        let pattern = #"(?<![\w])@([A-Za-z0-9_\-]+)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: m.range(at: 1)).lowercased()
            if let a = members.first(where: { handle($0).lowercased() == word }), !out.contains(id(a)) {
                out.append(id(a))
            }
        }
        return Array(out.prefix(3))
    }

    /// The @ being typed at the end of the text: what a suggestion list filters on. Nil when none.
    static func partialMention(_ text: String) -> String? {
        guard let r = text.range(of: #"(?<![\w])@([A-Za-z0-9_\-]*)$"#, options: .regularExpression) else { return nil }
        return String(text[r].dropFirst())
    }

    /// The text with the @ being typed finished as `@handle `.
    static func completing(_ text: String, with handle: String) -> String {
        guard let r = text.range(of: #"(?<![\w])@([A-Za-z0-9_\-]*)$"#, options: .regularExpression) else { return text }
        return text.replacingCharacters(in: r, with: "@\(handle) ")
    }

    /// Group sort: newest activity first.
    static func ordered(_ groups: [GroupInfo]) -> [GroupInfo] {
        groups.filter { $0.archivedAt == nil }.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
    }
}
