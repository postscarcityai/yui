import Foundation
import YuiLines

/// A reaction on an agent's message (YUI-49). Spec: yuigui/spec/REACTIONS.md,
/// the single source for the six and what they mean; `node spec/reactions.mjs
/// --check` there confirms this list matches.
struct Reaction: Identifiable, Equatable, Sendable {
    let emoji: String
    /// The short label under the bar and on the wire (`meaning="build it"`).
    let meaning: String
    var id: String { emoji }

    static let all: [Reaction] = [
        Reaction(emoji: "👍", meaning: "build it"),
        Reaction(emoji: "👎", meaning: "no"),
        Reaction(emoji: "🤔", meaning: "not sure"),
        Reaction(emoji: "❤️", meaning: "love it"),
        Reaction(emoji: "⏳", meaning: "later"),
        Reaction(emoji: "🔥", meaning: "priority"),
    ]

    static func named(_ emoji: String?) -> Reaction? { all.first { $0.emoji == emoji } }

    /// What the agent reads: the event line, then the start of the reacted
    /// message quoted, so it knows what the reaction answers.
    ///
    ///     [yui] react msg=<row id> emoji=👍 meaning="build it"
    ///     > Want me to set up Saturday? ...
    static func body(msg: String, reaction: Reaction?, changed: Bool, quoting text: String) -> String {
        var line = "[yui] react msg=\(msg) emoji=\(reaction?.emoji ?? "none")"
        if let reaction { line += " meaning=\(quote(reaction.meaning))" }
        if changed { line += " changed=true" }
        let q = Self.quote(message: text)
        return q.isEmpty ? line : line + "\n" + q
    }

    /// `{"react": {"msg": id, "emoji": "👍"}}`, emoji null when taken back.
    /// The server copies the emoji onto the reacted row from this.
    static func meta(msg: String, reaction: Reaction?) -> YLValue {
        .object(["react": .object(["msg": .string(msg), "emoji": reaction.map { .string($0.emoji) } ?? .null])])
    }

    /// The reaction a row of the thread sets, when it is a react event:
    /// (reacted row id, emoji or nil for taken back).
    static func from(meta: YLValue?) -> (msg: String, emoji: String?)? {
        guard let r = meta?.object?["react"]?.object, let msg = r["msg"]?.string else { return nil }
        return (msg.lowercased(), r["emoji"]?.string)
    }

    /// Up to 200 characters of the message, each line as `> `.
    static func quote(message text: String, limit: Int = 200) -> String {
        let flat = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty else { return "" }
        var cut = String(flat.prefix(limit))
        if cut.count < flat.count { cut = cut.trimmingCharacters(in: .whitespaces) + "…" }
        return cut.split(separator: "\n", omittingEmptySubsequences: true)
            .map { "> " + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
    }

    private static func quote(_ s: String) -> String {
        s.contains(where: \.isWhitespace) ? "\"\(s)\"" : s
    }
}

extension ChatMessage {
    /// The thread row this bubble came from: an agent reply splits into
    /// `<row id>#<n>` bubbles, and a reaction belongs to the whole row.
    var rowID: String { String(id.split(separator: "#", maxSplits: 1).first ?? Substring(id)) }
}
