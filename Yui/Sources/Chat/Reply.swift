import Foundation
import SwiftUI
import YuiLines

// Reply to one message (YUI-68, TestFlight feedback AG9JzU4LeWl-TFeKWftiFIE):
// hold a bubble or a card and tap Reply. No swipe: it took the sideways drag the
// pager needs (feedback AACnEo9w). The quote sits above the composer; sent, it rides an ordinary text row:
//   body  [yui] reply to=<row id> from=agent quote="first line"
//         <the words>
//   meta  {"reply_to": {"msg": "<row id>", "from": "agent", "quote": "first line"}}
// The app writes the line, like a reaction's, so every host (Hermes, OpenClaw,
// the webhook) hands it to the agent as is. Spec: yuigui/spec/RELAY.md.

/// The message a reply answers: its thread row, whose it was and its first line.
struct ReplyQuote: Equatable, Sendable {
    /// The thread row (an agent reply's bubbles share one).
    let msg: String
    /// Whose it was: the agent's, or the person's own.
    let fromUser: Bool
    /// Its first line (a card's title), short.
    let quote: String

    /// The longest quote, in characters.
    static let limit = 120

    /// The quote for a bubble or a card. nil when there is nothing to quote.
    init?(_ m: ChatMessage) {
        let text = m.yl.map(Self.title) ?? m.plain
        let line = Self.firstLine(text)
        guard !line.isEmpty || !m.photos.isEmpty else { return nil }
        self.init(msg: m.rowID, fromUser: m.fromUser,
                  quote: line.isEmpty ? Attachments.placeholder(m.photos.count) : line)
    }

    init(msg: String, fromUser: Bool, quote: String) {
        self.msg = msg.lowercased()
        self.fromUser = fromUser
        self.quote = quote
    }

    /// "Yui" or "You": who the quote is from, as the bar and the chip say it.
    func author(agent: String?) -> String { fromUser ? "You" : agent ?? "Yui" }

    /// The first non-empty line, capped at `limit` with an ellipsis.
    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        guard line.count > limit else { return line }
        return String(line.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// A card's name: the first thing on it with a title, a question or words.
    static func title(_ screen: YLScreen) -> String {
        for c in inChat(screen) {
            for key in ["title", "label", "q", "prompt", "text", "body"] {
                if let t = c.string(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
            }
        }
        return inChat(screen).first.map { $0.preset.capitalized } ?? ""
    }

    /// The parts drawn in the chat first (a `>2` line lives on its screen), then the rest.
    private static func inChat(_ screen: YLScreen) -> [YLComponent] {
        let chat = screen.top.filter { $0.page == 1 }
        return chat + screen.components.filter { c in !chat.contains { $0.serial == c.serial } }
    }

    /// Everything a card says, one line each, for Copy and Select text.
    static func words(_ screen: YLScreen) -> String {
        var out: [String] = []
        for c in inChat(screen) {
            for key in ["title", "label", "q", "prompt", "text", "body"] {
                if let t = c.string(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !out.contains(t) {
                    out.append(t)
                }
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: Wire

    /// What the agent reads: the reply line, then the person's words.
    static func body(_ words: String, replyingTo q: ReplyQuote?) -> String {
        guard let q else { return words }
        return line(q) + "\n" + words
    }

    /// `[yui] reply to=<row id> from=agent quote="..."`
    static func line(_ q: ReplyQuote) -> String {
        let quote = q.quote.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "[yui] reply to=\(q.msg) from=\(q.fromUser ? "user" : "agent") quote=\"\(quote)\""
    }

    /// The bubble's words from a row's body: the reply line comes off.
    static func words(body: String, meta: YLValue?) -> String {
        guard from(meta: meta) != nil, body.hasPrefix("[yui] reply ") else { return body }
        guard let nl = body.firstIndex(of: "\n") else { return "" }
        return String(body[body.index(after: nl)...])
    }

    /// `{"reply_to": {...}}` added to whatever meta the row already has (photos).
    static func meta(_ base: YLValue?, replyingTo q: ReplyQuote?) -> YLValue? {
        guard let q else { return base }
        var o = base?.object ?? [:]
        o["reply_to"] = .object(["msg": .string(q.msg), "from": .string(q.fromUser ? "user" : "agent"),
                                 "quote": .string(q.quote)])
        return .object(o)
    }

    /// The quote a row carries, if it is a reply.
    static func from(meta: YLValue?) -> ReplyQuote? {
        guard let r = meta?.object?["reply_to"]?.object, let msg = r["msg"]?.string, !msg.isEmpty else { return nil }
        return ReplyQuote(msg: msg, fromUser: r["from"]?.string == "user", quote: r["quote"]?.string ?? "")
    }
}

extension ChatMessage {
    /// What Copy and Select text take: a bubble's words, a card's lines.
    var words: String { yl.map(ReplyQuote.words) ?? plain }

    /// The words as drawn: an agent's markdown marks come off (YUI-76), the person's stay.
    var plain: String { fromUser ? text : BubbleMarkdown.plain(text) }
}

/// Above the composer while a reply is set: whose message, its first line, and an x.
struct ReplyBar: View {
    let quote: ReplyQuote
    let agent: String?
    let cancel: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        HStack(spacing: theme.spacing.m) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(c.accent)
            RoundedRectangle(cornerRadius: 2).fill(c.accent).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(quote.author(agent: agent))")
                    .font(theme.font(theme.type.caption, .heavy))
                    .foregroundStyle(c.accent)
                Text(quote.quote)
                    .font(theme.font(theme.type.caption, .semibold))
                    .foregroundStyle(c.inkSoft)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("reply-bar")
            Button(action: cancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(c.surface, c.inkSoft)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel reply")
            .accessibilityIdentifier("reply-cancel")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, theme.spacing.m)
        .padding(.vertical, theme.spacing.xs)
        .background(c.surface, in: .rect(cornerRadius: theme.radius.bubbleTail + 6))
        .overlay(RoundedRectangle(cornerRadius: theme.radius.bubbleTail + 6).stroke(c.outline, lineWidth: 1))
    }
}

/// Over a sent reply: whose message it answered and its first line. Tap: back to it.
struct ReplyChip: View {
    let quote: ReplyQuote
    let agent: String?
    let go: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        Button(action: go) {
            HStack(spacing: theme.spacing.s) {
                RoundedRectangle(cornerRadius: 1.5).fill(c.accent).frame(width: 3)
                VStack(alignment: .leading, spacing: 0) {
                    Text(quote.author(agent: agent))
                        .font(theme.font(theme.type.caption, .heavy))
                        .foregroundStyle(c.accent)
                    Text(quote.quote)
                        .font(theme.font(theme.type.caption, .medium))
                        .foregroundStyle(c.inkSoft)
                        .lineLimit(1)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, theme.spacing.m)
            .padding(.vertical, theme.spacing.xs + 2)
            .background(c.surface, in: .rect(cornerRadius: theme.radius.bubbleTail + 6))
            .overlay(RoundedRectangle(cornerRadius: theme.radius.bubbleTail + 6).stroke(c.outline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reply to \(quote.author(agent: agent)): \(quote.quote)")
        .accessibilityHint("Shows the message")
        .accessibilityIdentifier("reply-chip")
    }
}
