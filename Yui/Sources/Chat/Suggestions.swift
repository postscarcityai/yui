import SwiftUI

/// One row in the composer's suggestion popover: a slash command (YUI-61) or
/// an @mention of another agent (YUI-44). `title` is what the row shows first (`/new`),
/// `hint` its arguments (`[name]`), `detail` the one-line description.
struct Suggestion: Identifiable, Equatable {
    let id: String
    let title: String
    var hint: String? = nil
    var detail: String = ""
    /// What the composer holds after a tap.
    let fill: String
    /// An @mention row's agent: its face leads the row (YUI-44).
    var agent: YuiAgent? = nil
}

/// Suggestions over the composer, filtered as the person types. Tap one and
/// `pick` gets it; the popover itself holds no state, so any trigger (/, @)
/// can drive it.
struct SuggestionPopover: View {
    let items: [Suggestion]
    let pick: (Suggestion) -> Void
    /// Accessibility identifier of the popover; rows are `<identifier>-<id>`.
    var identifier = "suggestions"
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let c = theme.swatch(scheme)
        // A short list sizes to its rows; a long one scrolls in about four rows'
        // height, more when the text is bigger, never the whole screen.
        // (ViewThatFits stretched a two-row list to the full height, blank above and below.)
        let big = typeSize.isAccessibilitySize
        Group {
            if items.count <= (big ? 2 : 4) {
                list(c).fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView { list(c) }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: big ? 320 : 248)
            }
        }
        .background(c.surface, in: .rect(cornerRadius: theme.radius.bubbleTail + 10))
        .overlay(RoundedRectangle(cornerRadius: theme.radius.bubbleTail + 10).stroke(c.outline, lineWidth: 1.5))
        .clipShape(.rect(cornerRadius: theme.radius.bubbleTail + 10))
        .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.08), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private func list(_ c: Swatch) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { s in
                Button { pick(s) } label: { row(s, c) }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(s.detail.isEmpty ? s.title : "\(s.title), \(s.detail)")
                    .accessibilityHint(s.hint.map { "Takes \($0)" } ?? "")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("\(identifier)-\(s.id)")
                if s.id != items.last?.id {
                    Rectangle().fill(c.outline.opacity(0.6)).frame(height: 1)
                        .padding(.leading, theme.spacing.l)
                }
            }
        }
    }

    private func row(_ s: Suggestion, _ c: Swatch) -> some View {
        HStack(spacing: theme.spacing.m) {
            if let a = s.agent { AgentBadge(agent: a, size: 32).accessibilityHidden(true) }
            words(s, c)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, theme.spacing.l)
        .padding(.vertical, theme.spacing.s)
        .contentShape(Rectangle())
    }

    private func words(_ s: Suggestion, _ c: Swatch) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: theme.spacing.xs) {
                Text(s.title)
                    .font(theme.font(theme.type.body, .heavy))
                    .foregroundStyle(c.accent)
                if let hint = s.hint {
                    Text(hint)
                        .font(theme.font(theme.type.caption, .semibold))
                        .foregroundStyle(c.inkSoft)
                        .lineLimit(1)
                }
            }
            if !s.detail.isEmpty {
                Text(s.detail)
                    .font(theme.font(theme.type.caption))
                    .foregroundStyle(c.ink)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Typing / at the start of the composer (YUI-61): the agent's own commands.
enum SlashCommands {
    /// The word being typed after a leading slash, or nil when the draft is not
    /// a command still being named (no slash, or the name is done: a space).
    static func query(_ draft: String) -> String? {
        guard draft.hasPrefix("/") else { return nil }
        let word = draft.dropFirst()
        guard !word.contains(where: \.isWhitespace), !word.contains("/") else { return nil }
        return word.lowercased()
    }

    /// Commands that start with the query first, then ones that contain it,
    /// each group in the host's order. Empty when a finished name is the only fit.
    static func matches(_ draft: String, in commands: [AgentCommand]?) -> [AgentCommand] {
        guard let commands, !commands.isEmpty, let q = query(draft) else { return [] }
        if q.isEmpty { return commands }
        let starts = commands.filter { $0.name.hasPrefix(q) }
        let inside = commands.filter { !$0.name.hasPrefix(q) && $0.name.contains(q) }
        let all = starts + inside
        if all.count == 1, all[0].name == q { return [] }
        return all
    }

    /// What a tap leaves in the composer: the command, and a space when it takes arguments.
    static func fill(_ c: AgentCommand) -> String {
        "/\(c.name)" + ((c.args ?? "").isEmpty ? "" : " ")
    }

    static func suggestions(_ draft: String, in commands: [AgentCommand]?) -> [Suggestion] {
        matches(draft, in: commands).map {
            Suggestion(id: $0.name, title: "/\($0.name)", hint: $0.args, detail: $0.description, fill: fill($0))
        }
    }
}
