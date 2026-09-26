import Foundation
import SwiftUI
import YuiLines

// @mention another of your agents (YUI-44). Type @ anywhere in the composer and
// your other agents come up (face, name, presence); a tap puts `@Name ` in the
// draft. Sent, it is one ordinary text row in this thread:
//   body  [yui] mention to=<handle>
//         <the words>
//   meta  {"mention": {"to": "<agent id>", "handle": "coach", "name": "Coach"}}
// Yui does the rest (spec yuigui/spec/RELAY.md "Mentions"): this agent is not
// asked, the other one gets the words with this thread's last lines, and its
// answer comes back here as an agent row with meta.mention_reply, drawn in its
// own look with a way into its own thread.

/// Who a mirrored message is from: another agent answering a mention here.
struct MentionFrom: Equatable, Sendable {
    let agentID: String
    let name: String
    /// "asleep", "offline", "pending", "muted": Yui saying it can't answer yet.
    var status: String? = nil
}

enum Mentions {
    /// The name being typed after an @ at the end of the draft, lowercased.
    /// nil when the draft doesn't end in one (no @, or a space came after it).
    static func query(_ draft: String) -> String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at > draft.startIndex, !draft[draft.index(before: at)].isWhitespace { return nil }  // me@example.com
        let word = draft[draft.index(after: at)...]
        guard !word.contains(where: { $0.isWhitespace || $0 == "@" }) else { return nil }
        return word.lowercased()
    }

    /// The person's other agents that fit the query: names that start with it
    /// first, then ones that contain it. Never the agent you're in.
    static func matches(_ draft: String, agents: [YuiAgent], current: String?) -> [YuiAgent] {
        guard let q = query(draft) else { return [] }
        let others = agents.filter { $0.id != current }
        if q.isEmpty { return others }
        func starts(_ a: YuiAgent) -> Bool { a.name.lowercased().hasPrefix(q) || a.handle.hasPrefix(q) }
        func inside(_ a: YuiAgent) -> Bool { a.name.lowercased().contains(q) || a.handle.contains(q) }
        let all = others.filter(starts) + others.filter { !starts($0) && inside($0) }
        if all.count == 1, all[0].name.lowercased() == q { return [] }  // already typed in full
        return all
    }

    /// The draft after a tap: the half-typed @word becomes `@Name `.
    static func fill(_ draft: String, with a: YuiAgent) -> String {
        guard let at = draft.lastIndex(of: "@") else { return draft + "@\(a.name) " }
        return String(draft[..<at]) + "@\(a.name) "
    }

    static func suggestions(_ draft: String, agents: [YuiAgent], current: String?) -> [Suggestion] {
        matches(draft, agents: agents, current: current).map {
            Suggestion(id: $0.handle, title: $0.name, hint: "@\($0.handle)", detail: presence($0),
                       fill: fill(draft, with: $0), agent: $0)
        }
    }

    /// One word on how the agent is doing, the way the agent list says it.
    static func presence(_ a: YuiAgent) -> String {
        switch a.liveness {
        case .online: return a.muted ? "Online, muted" : "Online"
        case .asleep: return "Asleep"
        case .offline: return "Offline"
        case .pending: return "Not connected yet"
        case .notListening: return "Not listening yet"
        case .paused: return "Paused by its owner"
        }
    }

    /// The agent a draft mentions: the first `@Name` or `@handle` in it that is
    /// one of the person's other agents. One per message for now.
    static func target(_ text: String, agents: [YuiAgent], current: String?) -> YuiAgent? {
        let lower = text.lowercased()
        var best: (String.Index, YuiAgent)?
        for a in agents where a.id != current {
            for word in Set([a.name.lowercased(), a.handle]) where !word.isEmpty {
                var from = lower.startIndex
                while let r = lower.range(of: "@" + word, range: from..<lower.endIndex) {
                    let before = r.lowerBound == lower.startIndex || lower[lower.index(before: r.lowerBound)].isWhitespace
                    let after = r.upperBound == lower.endIndex || !(lower[r.upperBound].isLetter || lower[r.upperBound].isNumber)
                    if before, after {
                        if best == nil || r.lowerBound < best!.0 { best = (r.lowerBound, a) }
                        break
                    }
                    from = r.upperBound
                }
            }
        }
        return best?.1
    }

    // MARK: Wire

    /// `[yui] mention to=<handle>` then the words.
    static func body(_ words: String, to a: YuiAgent) -> String { "[yui] mention to=\(a.handle)\n" + words }

    static func meta(_ base: YLValue?, to a: YuiAgent) -> YLValue {
        var o = base?.object ?? [:]
        o["mention"] = .object(["to": .string(a.id), "handle": .string(a.handle), "name": .string(a.name)])
        return .object(o)
    }

    /// The name a person's row mentions, if it is a mention.
    static func to(meta: YLValue?) -> String? {
        guard let m = meta?.object?["mention"]?.object else { return nil }
        return m["name"]?.string ?? m["handle"]?.string
    }

    /// The bubble's words: the mention line comes off.
    static func words(body: String, meta: YLValue?) -> String {
        guard to(meta: meta) != nil, body.hasPrefix("[yui] mention ") else { return body }
        guard let nl = body.firstIndex(of: "\n") else { return "" }
        return String(body[body.index(after: nl)...])
    }

    /// A mention that reached this thread from another: "You, from Alpha's thread"
    /// (the person asked) or "From Alpha" (that agent asked, in a turn you started).
    static func arrived(meta: YLValue?) -> String? {
        guard let m = meta?.object?["mentioned"]?.object else { return nil }
        let name = m["from_name"]?.string ?? m["from_handle"]?.string ?? "another agent"
        return m["by"]?.string == "agent" ? "From \(name)" : "You, from \(name)'s thread"
    }

    /// The words of a mention that reached this thread: Yui's header line and the
    /// other thread's quoted lines come off (the agent reads them, the bubble doesn't).
    static func arrivedWords(body: String) -> String {
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.hasPrefix("[yui] mention ") == true else { return body }
        lines.removeFirst()
        if lines.first?.hasSuffix("'s thread, just before:") == true {
            lines.removeFirst()
            while lines.first?.hasPrefix("> ") == true { lines.removeFirst() }
        }
        return lines.joined(separator: "\n")
    }

    /// Another agent's answer (or Yui's status line for it) copied into this thread.
    static func from(meta: YLValue?) -> MentionFrom? {
        guard let m = meta?.object?["mention_reply"]?.object, let id = m["agent"]?.string else { return nil }
        return MentionFrom(agentID: id.lowercased(), name: m["name"]?.string ?? "Agent", status: m["status"]?.string)
    }
}

/// Above the composer while the draft mentions someone: who gets it, and how they are.
struct MentionBar: View {
    let agent: YuiAgent
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        HStack(spacing: theme.spacing.s) {
            AgentBadge(agent: agent, size: 24)
            Text("Goes to \(agent.name)")
                .font(theme.font(theme.type.caption, .heavy))
                .foregroundStyle(c.ink)
            Text(Mentions.presence(agent))
                .font(theme.font(theme.type.caption, .semibold))
                .foregroundStyle(c.inkSoft)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, theme.spacing.m)
        .padding(.vertical, theme.spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mention-bar")
    }
}

/// On the person's own bubble: which agent it went to, or which thread it came from.
struct MentionChip: View {
    let label: String
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        Label(label, systemImage: "at")
            .font(theme.font(theme.type.caption, .bold))
            .foregroundStyle(c.inkSoft)
            .accessibilityIdentifier("mention-chip")
    }
}

/// Over another agent's answer here: its name in its own color, and its thread one tap away.
struct MentionHeader: View {
    let from: MentionFrom
    var open: (() -> Void)?
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        HStack(spacing: theme.spacing.s) {
            Text(from.name)
                .font(theme.font(theme.type.caption, .black))
                .foregroundStyle(c.accent)
            if let open {
                Button(action: open) {
                    Label("Open its thread", systemImage: "arrow.up.right")
                        .font(theme.font(theme.type.caption, .bold))
                        .foregroundStyle(c.inkSoft)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(from.name)'s thread")
                .accessibilityIdentifier("mention-open-\(from.agentID)")
            }
        }
    }
}
